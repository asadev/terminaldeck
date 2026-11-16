import AppKit
import Foundation
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// What the first real two-Mac proof (13 Nov) found on the Cloud page, besides sync itself.
@Suite("Cloud account — two-Mac proof fixes", .serialized)
@MainActor
struct CloudAccountPolishUITests {
    // MARK: 1. the device list refreshes by itself

    @Test func theDeviceListIsAskedAboutOnceAMinuteWithThePageOpenAndNeverSignedOut() {
        let minute: UInt64 = 60_000_000_000
        #expect(NativeCloudAccount.deviceCheckInterval(pageOpen: true) == minute)
        #expect(NativeCloudAccount.deviceCheckInterval(pageOpen: false) == 5 * minute)
        #expect(NativeCloudAccount.deviceCheckDue(phase: .signedIn, pageOpen: true, sinceLast: minute))
        #expect(!NativeCloudAccount.deviceCheckDue(phase: .signedIn, pageOpen: true, sinceLast: minute - 1))
        #expect(!NativeCloudAccount.deviceCheckDue(phase: .signedIn, pageOpen: false, sinceLast: 2 * minute))
        #expect(NativeCloudAccount.deviceCheckDue(phase: .paused, pageOpen: false, sinceLast: 5 * minute))
        for phase in [CloudAccountSnapshot.Phase.signedOut, .signingIn, .needsSignIn, .dormant] {
            #expect(!NativeCloudAccount.deviceCheckDue(phase: phase, pageOpen: true, sinceLast: 100 * minute))
        }
        // A model with no account asks nothing, whatever it is told.
        let model = NativeCloudAccount()
        model.pageShown(true)
        #expect(model.pageOpen)
        model.checkDevices(minimumGap: 0)
        model.pageShown(false)
        #expect(!model.pageOpen)
    }

    // MARK: 2. sign-out removes this device; removed and stale entries are not shown

    @Test func theDevicesListShowsNeitherRemovedNorStaleEntries() {
        func row(_ id: String, _ standing: CloudDeviceTrustRow.Standing, removed: Bool = false, stale: Bool = false) -> CloudDeviceTrustRow {
            .init(deviceId: id, name: "Studio b", standing: standing, code: nil, keyId: nil, signKey: nil, removed: removed, stale: stale)
        }
        let rows = [row("10000000-0000-4000-8000-00000000000a", .thisMac),
                    row("10000000-0000-4000-8000-00000000000b", .trusted, stale: true),
                    row("10000000-0000-4000-8000-00000000000c", .new, removed: true),
                    row("10000000-0000-4000-8000-00000000000d", .trusted)]
        #expect(NativeCloudSettings.shownDevices(rows).map(\.deviceId) == ["10000000-0000-4000-8000-00000000000a", "10000000-0000-4000-8000-00000000000d"])
        #expect(!row("10000000-0000-4000-8000-00000000000e", .new, stale: true).canBeTrusted)
    }

    // MARK: 3. one plain question before signing out

    @Test func signOutAsksFirstAndSaysWhatStays() async {
        let model = NativeCloudAccount()
        var asked: [(String, String, String)] = []
        model.asker = { title, text, yes in asked.append((title, text, yes)); return false }
        #expect(await model.pressSignOut() == false)
        #expect(asked.count == 1)
        #expect(asked.first?.0 == "Sign out of Cloud on this Mac?")
        #expect(asked.first?.1 == "Your work stays on this Mac. It stops syncing with your other devices until you sign in again.")
        #expect(asked.first?.2 == "Sign out")
        model.asker = { _, _, _ in true }
        #expect(await model.pressSignOut())
        // The question itself: "Cancel" is the default (Return), "Sign out" takes a click.
        let alert = NativeCloudAccount.questionAlert(NativeCloudAccount.signOutTitle, NativeCloudAccount.signOutText,
                                                     yes: NativeCloudAccount.signOutYes, no: NativeCloudAccount.refusal(forYes: NativeCloudAccount.signOutYes))
        #expect(alert.messageText == "Sign out of Cloud on this Mac?")
        #expect(alert.buttons.map(\.title) == ["Cancel", "Sign out"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        // Afterwards the page is the signed-out page with "Sign in".
        model.fixtureSnapshot(.signedOut)
        #expect(NativeCloudSignInPage.content(model.signInStage).button == "Sign in")
    }

    // MARK: 4. the first Sign in press answers at once

    @Test func thisMacsNameIsReadWithoutTheNetwork() {
        let started = Date()
        let name = NativeCloudApplication.localDeviceName()
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(!name.isEmpty)
        // The same form the account always listed ("name.local"), so Macs keep their names.
        #expect(name.hasSuffix(".local") || !name.contains(" "))
    }
    /// 13 Nov: a saved sign-in waiting for Cloud is never the Sign in page; its button checks again, it starts no sign-in.
    @Test func aSavedSignInWaitingForCloudIsNotTheSignInPage() {
        let content = NativeCloudSignInPage.content(.reaching(name: "Owner"))
        #expect(content.button == "Check again")
        #expect(content.enabled)
        #expect(content.line.hasPrefix("You are signed in as Owner."))
        #expect(content.line != NativeCloudSignInPage.signedOutLine)
        #expect(BackendCloudAccount.waitAnswer(CloudFailure.budgetPaused))
        #expect(BackendCloudAccount.waitAnswer(CloudFailure.remote(.init(code: "rate_limited", message: "x", retryable: true, requestId: "r"))))
        #expect(!BackendCloudAccount.waitAnswer(CloudFailure.unavailable))
        #expect(BackendCloudAccount.waitProblem(at: Date()).contains("You are still signed in"))
    }
    @Test func thePressShowsSigningInBeforeAnythingIsBuilt() async {
        let model = NativeCloudAccount()
        // An account that takes a while to set up (none is built in a test process).
        model.arm({ try? await Task.sleep(for: .milliseconds(200)); return nil })
        model.pressSignIn()
        // Answered on the press itself, before the account exists.
        #expect(NativeCloudSignInPage.content(model.signInStage) == (NativeCloudSignInPage.signedOutLine, "Signing in…", false))
        while model.pressing { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(NativeCloudSignInPage.content(model.signInStage).button == "Sign in")
    }
}
