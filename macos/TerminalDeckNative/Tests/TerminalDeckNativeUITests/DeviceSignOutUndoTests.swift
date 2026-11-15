import Foundation
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Owner, 14 Nov: the row's action on Settings → Devices signs that device out (the Cloud ends its sign-in, reach cuts
/// its live connections here), after 5 seconds behind "Signing out… Undo". Undo and leaving the page cancel; this
/// Mac's own row has no such action; a device holding the saved-passwords key keeps everything and the row says why;
/// an old device keeps its old Remove. No clock waits: the delay is handed in.
@MainActor
final class DeviceSignOutUndoTests: XCTestCase {
    @MainActor final class Spy {
        var signedOut: [String] = []
        var cut: [String] = []
        var oldRemoved = 0
        var refusal: (any Error)?
        var outcome = BackendDeviceSignOutOutcome.signedOut
        var cutFailure: (any Error)?
    }
    private func model(_ spy: Spy, waits: Bool) -> NativeDeviceSignOut {
        let actions = NativeDeviceSignOut.Actions(
            signOut: { id in if let refusal = spy.refusal { throw refusal }; spy.signedOut.append(id); return spy.outcome },
            cut: { id in if let failure = spy.cutFailure { throw failure }; spy.cut.append(id) })
        // "waits": the 5 seconds never pass by themselves (only a cancel ends them); otherwise they pass at once.
        // Integrator: the closure ternary crashed the type checker ("failed to produce diagnostic"); typed branches instead.
        let wait: @Sendable (Duration) async throws -> Void
        if waits { wait = { _ in try await Task.sleep(for: .seconds(3600)) } } else { wait = { _ in } }
        return NativeDeviceSignOut(actions: actions, wait: wait)
    }
    private var rows: [NativeDevicesSettings.Row] {
        let account = [DevicesPage.AccountDevice(name: "MacBook Pro", kind: .mac, isThisMac: true, addedAtMs: nil, lastSeenAtMs: 3, deviceId: "this-mac-id"),
                       DevicesPage.AccountDevice(name: "Pixel", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: 2, deviceId: "pixel"),
                       DevicesPage.AccountDevice(name: "Mac mini", kind: .mac, isThisMac: false, addedAtMs: nil, lastSeenAtMs: 1, deviceId: "mini")]
        let old = [DevicesPage.OldDevice(ref: "device:o1", source: .device, name: "Old iPhone", lastSeenAtMs: 0.5, connected: false)]
        return NativeDevicesSettings.rows(account: account, old: old, now: Date(timeIntervalSince1970: 1))
    }
    private func row(_ name: String) throws -> NativeDevicesSettings.Row { try XCTUnwrap(rows.first { $0.name == name }) }

    func testSignOutCallsBothRoutesForTheChosenDeviceOnly() async throws {
        let spy = Spy(), model = model(spy, waits: false)
        let pixel = try row("Pixel")
        XCTAssertEqual(pixel.actionTitle, "Sign out this device")
        model.choose(pixel)
        XCTAssertTrue(model.pending.contains(pixel.id), "the row shows Signing out… Undo first")
        await model.settle()
        XCTAssertEqual(spy.signedOut, ["pixel"], "the Cloud ends the chosen device's sign-in, and no other")
        XCTAssertEqual(spy.cut, ["pixel"], "reach cuts the same device's live connections")
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertNil(model.notes[pixel.id])
        XCTAssertEqual(NativeDeviceSignOut.undoDelay, .seconds(5))
    }

    func testUndoWithinFiveSecondsCancels() async throws {
        let spy = Spy(), model = model(spy, waits: true)
        let mini = try row("Mac mini")
        model.choose(mini)
        XCTAssertEqual(NativeDeviceSignOut.pendingWord(mini), "Signing out…")
        model.undo(mini.id)
        await model.settle()
        XCTAssertEqual(spy.signedOut, [])
        XCTAssertEqual(spy.cut, [])
        XCTAssertTrue(model.pending.isEmpty)
        // A second choice after Undo starts again from the beginning.
        model.choose(mini)
        XCTAssertTrue(model.pending.contains(mini.id))
        model.undo(mini.id)
        await model.settle()
        XCTAssertEqual(spy.signedOut, [])
    }

    func testLeavingThePageCancels() async throws {
        let spy = Spy(), model = model(spy, waits: true)
        model.choose(try row("Pixel"))
        model.choose(try row("Mac mini"))
        model.cancelAll() // what the page's onDisappear does
        await model.settle()
        XCTAssertEqual(spy.signedOut, [])
        XCTAssertEqual(spy.cut, [])
        XCTAssertTrue(model.pending.isEmpty)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/NativeDevicesSettings.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".onDisappear { signOut.cancelAll()"), "leaving the page cancels")
        XCTAssertTrue(source.contains("NSApplication.willTerminateNotification"), "quitting cancels")
        XCTAssertFalse(source.contains("UserDefaults"), "a waiting sign-out is never saved, so it cannot fire later")
    }

    func testThisMacsRowHasNoSuchAction() async throws {
        let spy = Spy(), model = model(spy, waits: false)
        let mine = try row("MacBook Pro")
        XCTAssertTrue(mine.isThisMac)
        XCTAssertFalse(mine.canDisconnect)
        model.choose(mine)
        XCTAssertTrue(model.pending.isEmpty)
        await model.settle()
        XCTAssertEqual(spy.signedOut, [])
        XCTAssertEqual(spy.cut, [])
    }

    func testRotationRequiredLeavesEverythingAsItWas() async throws {
        let spy = Spy(), model = model(spy, waits: false)
        spy.refusal = BackendDeviceSignOutRefusal.holdsSavedPasswordsKey
        let mini = try row("Mac mini")
        model.choose(mini)
        await model.settle()
        XCTAssertEqual(spy.signedOut, [])
        XCTAssertEqual(spy.cut, [], "nothing is removed: not even reach")
        let note = try XCTUnwrap(model.notes[mini.id])
        XCTAssertEqual(note, NativeDeviceSignOut.holdsKeyLine)
        // Lost-device design (15 Nov, 5aefefe6c): another device CAN sign it out now; until the Cloud update that makes
        // the new key, the row says plainly that nothing was changed.
        XCTAssertTrue(note.contains("Nothing was changed"))
        for code in ["rotation", "409", "_"] { XCTAssertFalse(note.contains(code), code) }
        // Any other failure: one plain line, nothing cut either.
        spy.refusal = CloudFailure.unavailable
        model.choose(mini)
        await model.settle()
        XCTAssertEqual(model.notes[mini.id], NativeDeviceSignOut.failedLine)
        XCTAssertEqual(spy.cut, [])
    }

    /// DEVICE-SIGNOUT-2 (security): a browser is a reach key the Cloud does not list, so reach's removal reaching the
    /// Cloud IS its sign-out. When that fails (or reach is not set up here) the row says so; nothing pretends.
    func testABrowserIsSignedOutOnlyWhenReachsRemovalReachesTheCloud() async throws {
        let spy = Spy(), model = model(spy, waits: false)
        spy.outcome = .notAnAccountDevice
        spy.cutFailure = BackendDeviceSignOutRefusal.notSignedIn // reach not set up on this Mac
        let pixel = try row("Pixel")
        model.choose(pixel)
        await model.settle()
        XCTAssertEqual(model.notes[pixel.id], "Could not sign it out. Try again.")
        spy.cutFailure = CloudFailure.unavailable // the Cloud was not told
        model.choose(pixel)
        await model.settle()
        XCTAssertEqual(model.notes[pixel.id], NativeDeviceSignOut.failedLine)
        spy.cutFailure = nil
        model.choose(pixel)
        await model.settle()
        XCTAssertNil(model.notes[pixel.id])
        XCTAssertEqual(spy.cut, ["pixel"])
        // A device the Cloud revoked is signed out whatever reach answers.
        spy.outcome = .signedOut; spy.cutFailure = CloudFailure.unavailable
        let mini = try row("Mac mini")
        model.choose(mini)
        await model.settle()
        XCTAssertNil(model.notes[mini.id])
        // The tool runs the same steps and fails the same way.
        spy.outcome = .notAnAccountDevice
        let actions = model.actions
        do { try await actions.signOutBoth("browser-key"); XCTFail("the tool must say it failed") } catch {}
    }

    func testOldPairedDeviceStillUsesTheOldPath() async throws {
        let spy = Spy(), model = model(spy, waits: false)
        let old = try row("Old iPhone")
        XCTAssertEqual(old.actionTitle, "Remove this device")
        XCTAssertEqual(NativeDeviceSignOut.pendingWord(old), "Removing…")
        model.choose(old) { spy.oldRemoved += 1 }
        await model.settle()
        XCTAssertEqual(spy.oldRemoved, 1)
        XCTAssertEqual(spy.signedOut, [])
        XCTAssertEqual(spy.cut, [])
    }

    func testTheLabelsAndMessagesSayWhatHappens() throws {
        XCTAssertEqual(NativeDevicesSettings.signOutTitle, "Sign out this device")
        XCTAssertEqual(NativeDevicesSettings.removeTitle, "Remove this device")
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["NativeDevicesSettings.swift", "NativeReachAccount.swift", "NativeCloudAccount.swift", "NativeMACHINESMCP.swift"] {
            let text = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/" + file), encoding: .utf8)
            XCTAssertFalse(text.contains("Disconnect from this Mac"), file)
        }
        XCTAssertTrue(MACHINESMCP.removeDescription.contains("sign-in to the account ends"))
        XCTAssertFalse(DevicesPage.saysRetiredWord(MACHINESMCP.removeDescription))
    }
}
