import AppKit
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// R3 in the window: the decision every trust and approval sheet takes at the press, and the close when remote
/// control of this Mac starts or ends. No window is shown and the real record is never read.
@Suite("Cloud sheet guard — a press after remote input is a refusal; sheets close on a remote session change")
@MainActor
struct CloudSheetGuardUITests {
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var last: UInt64?
        private var time: UInt64 = 100_000_000_000
        func post() { lock.withLock { last = time } }
        func advance(_ nanoseconds: UInt64) { lock.withLock { time += nanoseconds } }
        func guarded() -> BackendRemoteInputGuard {
            .init(lastPost: { self.lock.withLock { self.last } }, now: { self.lock.withLock { self.time } })
        }
    }
    @MainActor private final class Closed { var count = 0 }

    @Test func theAcceptingButtonCountsOnlyWithoutRecentRemoteInput() {
        let record = Record(), remote = record.guarded()
        let accept = NSApplication.ModalResponse.alertSecondButtonReturn, refuse = NSApplication.ModalResponse.alertFirstButtonReturn
        #expect(NativeCloudSheetGuard.accepted(accept, accept: accept, remote: remote))
        #expect(!NativeCloudSheetGuard.accepted(refuse, accept: accept, remote: remote))
        #expect(!NativeCloudSheetGuard.accepted(.abort, accept: accept, remote: remote))
        record.post()
        // "Trust this device", "Allow this device", "Codes match" and "Add this MCP server" all decide through this.
        #expect(!NativeCloudSheetGuard.accepted(accept, accept: accept, remote: remote))
        record.advance(BackendRemoteInputGuard.pressWindow)
        #expect(NativeCloudSheetGuard.accepted(accept, accept: accept, remote: remote))
        // The saved-passwords sheets use the same accepting buttons this guard is given.
        #expect(NativeCloudRecoveryInteraction.allowDeviceAccept == accept)
        #expect(NativeCloudRecoveryInteraction.transferConfirmationAccept == accept)
        #expect(NativeCloudTrustSheets.trustAccept == accept)
    }
    /// Full-suite fix (13 Nov): a Cloud background event (an arrival, a sync change, a trust notice) brings nothing to
    /// the front, so it never takes the keyboard from the session the person is typing in (0.21.4). In this test
    /// process another app is in front and nothing was pressed here: exactly a background event's situation.
    @Test func aCloudBackgroundEventBringsNothingToTheFront() throws {
        _ = NSApplication.shared
        // Never reach the modal below unless the gate is closed (it would wait for a press).
        try #require(!NativeFront.personActing)
        let guardian = NativeCloudSheetGuard.shared
        let before = guardian.shown
        let answer = guardian.presentWithoutWindow(NativeCloudAccount.questionAlert("Q", "T", yes: "Yes"), accept: NativeCloudAccount.questionAccept)
        #expect(!answer.chose && !answer.taken)
        #expect(guardian.shown == before)
        // Every Cloud call that raises a window or the app goes through NativeFront; a bare "front-ok:" marker is not
        // enough in a Cloud file (it must sit behind NativeFront.personActing).
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckNative", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("NativeCloud") && $0.pathExtension == "swift" }
        #expect(files.count > 10)
        var bare: [String] = []
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where line.contains(NativeFrontPolicy.allowMarker) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if !line.contains("NativeFront.personActing") { bare.append(file.lastPathComponent + ":\(index + 1)") }
            }
        }
        #expect(bare.isEmpty, Comment(rawValue: bare.joined(separator: "\n")))
    }
    @Test func theLastMacSignOutWarningRefusesOnReturn_R5() {
        let alert = NativeCloudAccount.lastSignOutAlert()
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].title == "Cancel")
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].title == "Sign out")
        #expect(alert.buttons[1].keyEquivalent == "")
        #expect(NativeCloudAccount.lastSignOutAccept == .alertSecondButtonReturn)
        // PASSWORDS-2: the truth for each kind of account (words only where an older account has them).
        #expect(!alert.informativeText.contains("recovery words") && alert.informativeText.contains("that copy is lost"))
        #expect(NativeCloudAccount.lastSignOutAlert(wordsOnFile: true).informativeText.contains("only your recovery words can open it again"))
    }
    @Test func theSignInAndMemoryQuestionsRefuseOnReturn_S9() {
        // Security review S9: the account's own questions are behind the same guard, and Return answers "Cancel".
        let alert = NativeCloudAccount.questionAlert("Sign in to Cloud as Fixture?", "Account: fixture@example.invalid", yes: "Sign In")
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].title == "Cancel")
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].title == "Sign In")
        #expect(alert.buttons[1].keyEquivalent == "")
        #expect(alert.buttons[1].refusesFirstResponder)
        #expect(NativeCloudAccount.questionAccept == .alertSecondButtonReturn)
        // The answer is decided by the same rule as a trust press.
        let record = Record(), remote = record.guarded()
        #expect(NativeCloudSheetGuard.accepted(NativeCloudAccount.questionAccept, accept: NativeCloudAccount.questionAccept, remote: remote))
        record.post()
        #expect(!NativeCloudSheetGuard.accepted(NativeCloudAccount.questionAccept, accept: NativeCloudAccount.questionAccept, remote: remote))
    }
    @Test func theCloudHereQuestionSaysBothDirectionsAndReturnAnswersNotNow_B4() {
        // Review B-M4 (Decker's decision): not about memory alone, both directions in words, "Not now" on Return.
        #expect(NativeCloudLaunch.cloudHereTitle == "Use your Cloud on this Mac?")
        #expect(NativeCloudLaunch.cloudHereText == "This Mac's memory, projects, agents and boot files are added to your Cloud, and what is in your Cloud comes to this Mac. Nothing is deleted on either side.")
        let no = NativeCloudAccount.refusal(forYes: NativeCloudLaunch.cloudHereYes)
        #expect(no == "Not now")
        #expect(NativeCloudAccount.refusal(forYes: "Sign In") == "Cancel")
        let alert = NativeCloudAccount.questionAlert(NativeCloudLaunch.cloudHereTitle, NativeCloudLaunch.cloudHereText, yes: NativeCloudLaunch.cloudHereYes, no: no)
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].title == "Not now")
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].title == "Use Cloud here")
        #expect(alert.buttons[1].keyEquivalent == "")
        #expect(alert.buttons[1].refusesFirstResponder)
        // The Cloud switch says the same two directions.
        #expect(NativeCloudSettings.useCloudToggle == "Use Cloud on this Mac")
        #expect(NativeCloudSettings.useCloudNote.contains("are not sent, and none arrive here"))
        // The old one-direction words are gone from the window.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let launch = (try? String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCompositionCloud.swift"), encoding: .utf8)) ?? ""
        let settings = (try? String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudSettings.swift"), encoding: .utf8)) ?? ""
        #expect(!launch.contains("Choose Cancel to keep them on this Mac only"))
        #expect(!settings.contains("stops sending memory"))
        #expect(!launch.isEmpty)
    }
    @Test func anAcceptingButtonTakesAClickAndCannotHoldTheKeyboardFocus_S6() throws {
        // Security review S6: with macOS keyboard navigation on, Space presses the focused button. The accepting
        // button of every guarded sheet refuses the focus, so only a click reaches it.
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "x", y: "y")
        let capture = BackendCloudTrustCapture(deviceId: "10000000-0000-4000-8000-00000000000a", name: "MacBook Air", signKey: key,
                                               keyId: String(repeating: "a", count: 64), code: "4F2A 91C3 B07E 55D1 8A2C")
        let trust = NativeCloudTrustSheets.trustAlert(capture, waiting: 0)
        #expect(trust.buttons[1].title == "Trust this device")
        #expect(trust.buttons[1].refusesFirstResponder)
        #expect(trust.buttons[1].keyEquivalent == "")
        #expect(!trust.buttons[0].refusesFirstResponder)
        let signOut = NativeCloudAccount.lastSignOutAlert()
        #expect(signOut.buttons[1].refusesFirstResponder)
        #expect(!signOut.buttons[0].refusesFirstResponder)
        // The one presenter does it for whatever alert it is handed, so a new sheet cannot forget it.
        let plain = NSAlert()
        plain.addButton(withTitle: "Not now")
        let accepting = plain.addButton(withTitle: "Accept")
        accepting.keyEquivalent = "\r"
        NativeCloudSheetGuard.harden(plain, accept: .alertSecondButtonReturn)
        #expect(accepting.refusesFirstResponder)
        #expect(accepting.keyEquivalent == "")
    }
    @Test func laneVsApprovalSheetsCannotBePressedWithTabAndSpace_SA6() throws {
        // Review S-A6: the accepting button of every saved-passwords approval sheet refuses the keyboard focus.
        let reset = NativeCloudRecoveryInteraction.resetAlert()
        #expect(reset.buttons[1].refusesFirstResponder)
        #expect(!reset.buttons[0].refusesFirstResponder)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sheets = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudRecoverySheets.swift"), encoding: .utf8)
        #expect(sheets.contains("NativeCloudSheetGuard.harden(alert, accept: transferConfirmationAccept)"))
        #expect(sheets.contains("NativeCloudSheetGuard.harden(alert, accept: allowDeviceAccept)"))
        #expect(sheets.contains("NativeCloudSheetGuard.harden(alert, accept: .alertSecondButtonReturn)"))
        #expect(sheets.contains("NativeCloudSheetGuard.harden(alert, accept: resetAccept)"))
    }
    @Test func pagePressesThatLetCloudInAreJudgedLikeASheetsAcceptingButton_SB4() throws {
        // Review S-B4: "Choose folder…", the Cloud switch and "Use Cloud here" are refused right after remote input.
        let record = Record(), remote = record.guarded()
        #expect(NativeCloudSheetGuard.pagePressAllowed(remote: remote, at: nil))
        record.post()
        #expect(!NativeCloudSheetGuard.pagePressAllowed(remote: remote, at: nil))
        record.advance(BackendRemoteInputGuard.pressWindow)
        #expect(NativeCloudSheetGuard.pagePressAllowed(remote: remote, at: nil))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let overview = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudOverview.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudSettings.swift"), encoding: .utf8)
        #expect(overview.contains("pagePress(model: model) { choose(projectId) }"))
        #expect(overview.contains("pagePress(model: model) { NativeCloudBrainRegistration.setMemoryIncluded(true) }"))
        #expect(settings.contains("pagePress(model: model) { NativeCloudBrainRegistration.setMemoryIncluded(value) }"))
        #expect(!settings.contains("set: { NativeCloudBrainRegistration.setMemoryIncluded($0) }"))
    }
    @Test func aPressCarriesItsOwnTime_S1() {
        // Only a click or a key press has a time worth judging; the time is seconds since this Mac started.
        #expect(NativeCloudSheetGuard.pressTime(type: .leftMouseUp, seconds: 12.5) == 12_500_000_000)
        #expect(NativeCloudSheetGuard.pressTime(type: .keyDown, seconds: 3) == 3_000_000_000)
        #expect(NativeCloudSheetGuard.pressTime(type: .mouseMoved, seconds: 12.5) == nil)
        #expect(NativeCloudSheetGuard.pressTime(type: .leftMouseUp, seconds: 0) == nil)
        #expect(NativeCloudSheetGuard.pressTime(type: .leftMouseUp, seconds: .infinity) == nil)
    }
    @Test func theAcceptSheetForAFileThatCanRunRefusesOnReturnAndShowsItsPlaceAndWhatRuns() throws {
        // Lean item 8: a boot file that can run a command is written only when the person accepts it on this Mac.
        let request = NativeCloudFileAcceptRequest(id: "f1", path: "Site/.claude/commands/deploy.md",
            runs: ["It runs a command while it loads: !`git push`", "It lets tools run without asking: Bash(git:*)"],
            from: "MacBook Air\nCode: 4F2A 91C3 B07E 55D1 8A2C", replaces: true)
        let alert = NativeCloudFileAcceptSheet.alert(request)
        // This Mac has a different file there, so a second refusing choice is offered: three buttons.
        #expect(alert.buttons.count == 3)
        #expect(alert.buttons[2].title == "Keep this Mac’s file")
        #expect(alert.buttons[2].keyEquivalent == "")
        let fresh = NativeCloudFileAcceptSheet.alert(NativeCloudFileAcceptRequest(id: "f2", path: "Site/.claude/skills/run.sh", runs: ["It is a script."]))
        #expect(fresh.buttons.count == 2)
        #expect(!fresh.informativeText.contains(NativeCloudFileAcceptSheet.replacesLine))
        #expect(alert.buttons[0].title == "Not now")
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].title == "Accept this file")
        #expect(alert.buttons[1].keyEquivalent == "")
        #expect(alert.buttons[1].refusesFirstResponder)
        #expect(NativeCloudFileAcceptSheet.accept == .alertSecondButtonReturn)
        // The sheet's own words carry nothing the other device chose.
        #expect(alert.messageText == "Accept this file from your Cloud?")
        #expect(!alert.informativeText.contains("deploy.md"))
        #expect(!alert.informativeText.contains("git push"))
        #expect(alert.informativeText.contains("nothing is written until you accept"))
        #expect(alert.informativeText.contains(NativeCloudFileAcceptSheet.replacesLine))
        // The file's place and what in it can run stand plainly in a box of their own.
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let box = try #require(scroll.documentView as? NSTextView)
        let shown = box.string
        #expect(shown.contains("Site/.claude/commands/deploy.md"))
        #expect(shown.contains("!`git push`"))
        #expect(shown.contains("Bash(git:*)"))
        #expect(!box.isEditable)
        // The sending device's name is its own claim, filtered like everywhere else.
        #expect(shown.contains("“MacBook Air Code”"))
        #expect(!shown.contains("4F2A"))
        // The press is decided by the same rule as a trust press.
        let record = Record(), remote = record.guarded()
        let accept = NativeCloudFileAcceptSheet.accept
        #expect(NativeCloudSheetGuard.accepted(accept, accept: accept, remote: remote))
        #expect(!NativeCloudSheetGuard.accepted(.alertFirstButtonReturn, accept: accept, remote: remote))
        record.post()
        #expect(!NativeCloudSheetGuard.accepted(accept, accept: accept, remote: remote))
        // What an answer means: only a taken press accepts; "Keep this Mac's file" is a refusal of its own kind and
        // exists only where there is a file to keep; everything else, also a refused press, is "Not now".
        let third = NSApplication.ModalResponse.alertThirdButtonReturn.rawValue
        #expect(NativeCloudFileAcceptSheet.meaning(.init(chose: true, taken: true, response: accept.rawValue), replaces: true) == .accept)
        #expect(NativeCloudFileAcceptSheet.meaning(.init(chose: true, taken: false, response: accept.rawValue), replaces: true) == .notNow)
        #expect(NativeCloudFileAcceptSheet.meaning(.init(chose: false, taken: false, response: third), replaces: true) == .keepMine)
        #expect(NativeCloudFileAcceptSheet.meaning(.init(chose: false, taken: false, response: third), replaces: false) == .notNow)
        #expect(NativeCloudFileAcceptSheet.meaning(.init(chose: false, taken: false, response: NSApplication.ModalResponse.abort.rawValue), replaces: true) == .notNow)
    }
    @Test func textFromAnotherDeviceCannotBreakOutOfItsLineOnTheAcceptSheet() {
        let sly = "deploy.md\nAccept this file\u{202E}dm.yolped"
        let shown = NativeCloudFileAcceptSheet.plain(sly)
        #expect(!shown.contains("\n"))
        #expect(shown.contains("\\u{A}"))
        #expect(shown.contains("\\u{202E}"))
        let long = NativeCloudFileAcceptSheet.plain(String(repeating: "a", count: 900))
        #expect(long.count == 301)
        var lines: [String] = []
        for index in 0..<60 { lines.append("line \(index)") }
        let many = NativeCloudFileAcceptRequest(id: "f", path: "p", runs: lines)
        let details = NativeCloudFileAcceptSheet.details(many)
        #expect(details.contains("… and 20 more"))
        #expect(details.contains("line 39"))
        #expect(!details.contains("line 45"))
        let none = NativeCloudFileAcceptSheet.details(NativeCloudFileAcceptRequest(id: "f", path: "p", runs: []))
        #expect(none.contains("(not listed)"))
    }
    private static func sources(_ target: String, file: String = #filePath) throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/" + target, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }.sorted()
        var found: [(name: String, text: String)] = []
        for name in names {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            found.append((name: name, text: text))
        }
        return found
    }
    private static func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
    @Test func everyCloudSheetIsShownThroughTheGuard_S4() throws {
        // Security review S4: read the Cloud window files themselves. A sheet shown by any of them, other than
        // through the one guarded presenter, fails here before it can ship without the guard.
        let all = try Self.sources("TerminalDeckNative")
        let files = all.filter { $0.name.hasPrefix("NativeCloud") || $0.name.hasPrefix("NativeCompositionCloud") }
        #expect(files.count >= 10)
        let calls = ["beginSheetModal(", ".runModal()", ".beginSheet("]
        var offenders: [String] = []
        for file in files where file.name != "NativeCloudSheetGuard.swift" && file.name != "NativeCloudRecoverySheets.swift" {
            for call in calls where file.text.contains(call) { offenders.append(file.name + " " + call) }
        }
        #expect(offenders.isEmpty, "a Cloud sheet is shown outside NativeCloudSheetGuard: \(offenders)")
        // The guard is where they are shown.
        let own = try #require(files.first(where: { $0.name == "NativeCloudSheetGuard.swift" }))
        #expect(own.text.contains("func present(_ alert: NSAlert, on window: NSWindow, accept: NSApplication.ModalResponse)"))
        #expect(Self.count("beginSheetModal(", in: own.text) >= 1)
        // Saved passwords' own sheets file (lane V) has ONE accepting path, which asks this guard at the press, the
        // set-up panel, and two notices with nothing to accept. Another sheet there must be looked at: it changes
        // these counts.
        let recovery = try #require(files.first(where: { $0.name == "NativeCloudRecoverySheets.swift" }))
        #expect(Self.count("beginSheetModal(", in: recovery.text) == 3)
        #expect(Self.count("NativeCloudSheetGuard.accepted(", in: recovery.text) == 1)
        #expect(Self.count(".beginSheet(", in: recovery.text) == 1)
        #expect(Self.count(".runModal()", in: recovery.text) == 0)
    }
    @Test func onlyTheSheetsCanReachTheTrustPress_S13() throws {
        // Security review S13: the press and the capture are package-level, and nothing but the two sheets (through
        // the account model) names them.
        let native = try Self.sources("TerminalDeckNative"), backend = try Self.sources("TerminalDeckBackend")
        let everything = native + backend
        let callers = everything.filter { $0.text.contains("trustDevices(") }.map { $0.name }
        #expect(callers == ["NativeCloudAccount.swift", "BackendCloudAccount.swift"])
        let makers = everything.filter { $0.text.contains("BackendCloudTrustCapture(") }.map { $0.name }
        #expect(makers == ["NativeCloudTrustSheets.swift"])
        let account = try #require(backend.first(where: { $0.name == "BackendCloudAccount.swift" }))
        #expect(account.text.contains("package func trustDevices("))
        #expect(!account.text.contains("public func trustDevices("))
        let trust = try #require(backend.first(where: { $0.name == "BackendCloudTrust.swift" }))
        // PASSWORDS-2: the capture also keeps the device's kind; still package-level only, still made only by the sheets.
        #expect(trust.text.contains("package init(deviceId: String, name: String, signKey: CloudPublicJWK, keyId: String, code: String, platform: CloudPlatform? = nil)"))
        #expect(!trust.text.contains("public init(deviceId: String, name: String, signKey: CloudPublicJWK, keyId: String, code: String"))
        #expect(trust.text.contains("package init?(row: CloudDeviceTrustRow)"))
        // The list itself must be told how a press is checked: no default that means "never refused" (S2).
        #expect(trust.text.contains("pressRefused: @escaping @Sendable () -> Bool) {"))
        #expect(!trust.text.contains("pressRefused: @escaping @Sendable () -> Bool = "))
        // In the model the press is reached only from the trust sheet and the new-Mac sheet.
        let model = try #require(native.first(where: { $0.name == "NativeCloudAccount.swift" }))
        #expect(Self.count("service.trustDevices(", in: model.text) == 1)
        let reachers = native.filter { $0.text.contains("model.trust(") || $0.text.contains("model.useTicked(") }.map { $0.name }
        #expect(reachers == ["NativeCloudTrustSheets.swift"])
    }
    @Test func startingNewSavedPasswordsRefusesOnReturnAndNoToolOpensIt_V1() throws {
        // Security review V1: one stray Return must never start new saved passwords.
        let alert = NativeCloudRecoveryInteraction.resetAlert()
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].title == "Don’t start new")
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].title == "Start new saved passwords")
        #expect(alert.buttons[1].keyEquivalent == "")
        #expect(NativeCloudRecoveryInteraction.resetAccept == .alertSecondButtonReturn)
        // The one tool that is registered for saved passwords has no reset action at all.
        let schema = try BackendCloudSecretsLeanTool.definition().inputSchema.compact
        #expect(!schema.contains("reset"))
    }
    @Test func anOpenSheetClosesWhenRemoteControlStartsAndWhenItEnds() {
        let record = Record(), watch = NativeCloudSheetGuard(), closed = Closed()
        watch.remote = record.guarded()
        watch.interval = .seconds(3600) // the test looks by hand
        // Opened by the person with no remote control going on; nothing changes: it stays open.
        let first = watch.opened { closed.count += 1 }
        #expect(!watch.check())
        #expect(closed.count == 0)
        // A phone starts controlling this Mac: the sheet closes.
        record.post()
        #expect(watch.check())
        #expect(closed.count == 1)
        watch.closed(first)
        // A sheet opened while the phone is in control (perhaps by the phone) closes when that control ends.
        let second = watch.opened { closed.count += 1 }
        #expect(!watch.check())
        record.advance(BackendRemoteInputGuard.sessionWindow)
        #expect(watch.check())
        #expect(closed.count == 2)
        watch.closed(second)
        // Nothing registered: nothing to do.
        record.post()
        #expect(!watch.check())
        #expect(closed.count == 2)
        #expect(NativeCloudSheetGuard.sessionChanged(was: false, now: true))
        #expect(NativeCloudSheetGuard.sessionChanged(was: true, now: false))
        #expect(!NativeCloudSheetGuard.sessionChanged(was: true, now: true))
    }
}
