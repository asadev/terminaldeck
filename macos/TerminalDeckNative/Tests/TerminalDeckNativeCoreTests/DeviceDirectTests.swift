import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// Finding 3 (22 Oct 2026): the direct device path's pure rules — the keys a piece of typing is, the
/// finger steps of a tap or a swipe, the iOS helper's command lines, and which devices go direct.
@Suite struct DeviceDirectTests {
    @Test func lettersDigitsAndPunctuationAreUSKeys() throws {
        let strokes = try #require(DeviceDirectKeys.strokes("aZ1!\n "))
        #expect(strokes == [.init(4), .init(29, modifiers: [225]), .init(30), .init(30, modifiers: [225]), .init(40), .init(44)])
        #expect(DeviceDirectKeys.strokes("wifi")?.map(\.usage) == [26, 12, 9, 12])
        #expect(DeviceDirectKeys.strokes("a-b_c?/")?.count == 7)
    }

    @Test func typingWithoutAKeyGoesTheEngineWay() {
        #expect(DeviceDirectKeys.strokes("café") == nil)
        #expect(DeviceDirectKeys.strokes("سلام") == nil)
        #expect(DeviceDirectKeys.strokes("ok 👍") == nil)
        #expect(DeviceDirectKeys.strokes("")?.isEmpty == true)
    }

    @Test func namedKeys() {
        #expect(DeviceDirectKeys.named("return") == [.init(40)])
        #expect(DeviceDirectKeys.named("delete") == [.init(42)])
        #expect(DeviceDirectKeys.named("arrow-up") == [.init(82)])
        #expect(DeviceDirectKeys.named("select-all") == [.init(4, modifiers: [227])])
        #expect(DeviceDirectKeys.named("volume-up") == nil)
    }

    @Test func aPressHoldsItsModifiersAroundTheKey() {
        #expect(SimDirectLine.press(.init(29, modifiers: [225])) == "K 225 d\nK 29 d\nK 29 u\nK 225 u\n")
        #expect(SimDirectLine.press(.init(40)) == "K 40 d\nK 40 u\n")
    }

    @Test func touchLinesAreClampedAndOneOrTwoFingers() {
        #expect(SimDirectLine.touch(down: true, [(0.25, 0.75)]) == "T 1 0.25000 0.75000\n")
        #expect(SimDirectLine.touch(down: false, [(1.5, -2)]) == "U 1 1.00000 0.00000\n")
        #expect(SimDirectLine.touch(down: true, [(0.4, 0.4), (0.6, 0.6)]) == "T 2 0.40000 0.40000 0.60000 0.60000\n")
        #expect(SimDirectLine.touch(down: true, []) == nil)
        #expect(SimDirectLine.touch(down: true, [(.nan, 0.5)]) == "T 1 0.00000 0.50000\n")
    }

    @Test func onlyHomeAndLockArePressedByTheHelper() {
        #expect(SimDirectLine.button("home", down: true) == "B home d\n")
        #expect(SimDirectLine.button("lock", down: false) == "B lock u\n")
        #expect(SimDirectLine.button("volume-up", down: true) == nil)
        #expect(SimDirectLine.pause(true) == "P 1\n")
    }

    @Test func everyIPhoneButtonIsPressedByTheHelperOnCoreDevicesTouchscreen() {
        for name in ["home", "lock", "volume-up", "volume-down", "action"] {
            #expect(SimDirectLine.button(name, down: true, coreDevice: true) == "B \(name) d\n")
        }
        #expect(SimDirectLine.button("back", down: true, coreDevice: true) == nil)
    }

    @Test func helperSaysWhoseTouchscreenItIs() {
        #expect(SimDirectLine.ready("ready 1206 2622 touch=1 keys=1 buttons=1 hid=coredevice")?.coreDevice == true)
        #expect(SimDirectLine.ready("ready 1170 2532 touch=1 keys=1 buttons=1 hid=indigo")?.coreDevice == false)
        #expect(SimDirectLine.hid("hid coredevice") == true)
        #expect(SimDirectLine.hid("hid indigo") == false)
        #expect(SimDirectLine.hid("note anything") == nil)
    }

    @Test func eachTouchscreenHasItsOwnAbilities() {
        // Indigo's shape check failed, CoreDevice's touchscreen is reachable: only CoreDevice input goes the
        // helper's way; on Indigo it goes the engine's way, never into nothing (Reviewer, batch 2).
        let coreOnly = SimDirectLine.ready("ready 1206 2622 touch=0 keys=0 buttons=0 core=1 hid=indigo")
        #expect(coreOnly?.core == true)
        #expect(coreOnly?.touchNow == false)
        #expect(coreOnly?.keysNow == false)
        #expect(coreOnly?.buttonsNow == false)
        var changed = coreOnly
        changed?.coreDevice = true   // `hid coredevice`
        #expect(changed?.touchNow == true)
        #expect(changed?.keysNow == true)
        #expect(changed?.buttonsNow == true)
        let indigoOnly = SimDirectLine.ready("ready 1170 2532 touch=1 keys=1 buttons=1 core=0 hid=indigo")
        #expect(indigoOnly?.touchNow == true)
        #expect(indigoOnly?.keysNow == true)
    }

    @Test func typingThroughTheHelperIsLimitedBySize() {
        #expect(SimDirectLine.typing("aB", coreDevice: false) == "K 4 d\nK 4 u\nK 225 d\nK 5 d\nK 5 u\nK 225 u\n")
        let longest = String(repeating: "a", count: SimDirectLine.longestTyped)
        #expect(SimDirectLine.typing(longest, coreDevice: false) != nil)
        #expect(SimDirectLine.typing(longest + "a", coreDevice: false) == nil)
        // On CoreDevice's touchscreen: by the size of its key lines (8 KB), not by a character count.
        #expect(SimDirectLine.typing(String(repeating: "a", count: 600), coreDevice: true)?.utf8.count == 7_200)
        #expect(SimDirectLine.typing(String(repeating: "a", count: 700), coreDevice: true) == nil)
        #expect(SimDirectLine.typing(String(repeating: "A", count: 400), coreDevice: true) == nil)   // 4 lines each
        #expect(SimDirectLine.typing(String(repeating: "A", count: 250), coreDevice: true)?.utf8.count == 7_000)
        #expect(SimDirectLine.typing("caf\u{E9}", coreDevice: true) == nil)
    }

    @Test func readyLineSaysWhatTheHelperCanDo() {
        #expect(SimDirectLine.ready("ready 1170 2532 touch=1 keys=1 buttons=0")
                == .init(width: 1170, height: 2532, touch: true, keys: true, buttons: false))
        #expect(SimDirectLine.ready("ready 0 10") == nil)
        #expect(SimDirectLine.ready("error no screen") == nil)
    }

    @Test func aTapIsDownThenUpAfterItsHold() {
        let steps = DeviceDirectGesture.tap(x: 0.5, y: 0.2, holdMs: nil)
        #expect(steps.map(\.up) == [false, true])
        #expect(steps.last?.atMs == 70)
        #expect(DeviceDirectGesture.tap(x: 0, y: 0, holdMs: 800).last?.atMs == 800)
        #expect(DeviceDirectGesture.tap(x: 0, y: 0, holdMs: 1).last?.atMs == 40)
    }

    @Test func aSwipeMovesAboutSixtyTimesASecondThenLifts() {
        let steps = DeviceDirectGesture.swipe(fromX: 0.5, fromY: 0.8, toX: 0.5, toY: 0.2, ms: 320)
        #expect(steps.first == .init(atMs: 0, x: 0.5, y: 0.8, up: false))
        #expect(steps.dropLast().last?.y == 0.2)
        #expect(steps.last?.up == true)
        #expect(steps.filter { !$0.up }.count == 21)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.atMs <= $1.atMs })
        #expect(DeviceDirectGesture.swipe(fromX: 0, fromY: 0, toX: 1, toY: 1, ms: 1).filter { !$0.up }.count == 7)
    }

    @Test func simulatorsAndEmulatorsGoDirectPhonesDoNot() {
        let udid = "AD7A27CE-E2B2-407C-A4F7-72ED314432DB"
        #expect(DeviceDirectTarget(id: "ios:" + udid, platform: "ios", kind: "simulator") == .iosSimulator(udid: udid))
        #expect(DeviceDirectTarget(id: "ios:not-a-udid", platform: "ios", kind: "simulator") == nil)
        #expect(DeviceDirectTarget(id: "ios:" + udid, platform: "ios", kind: "physical") == nil)
        #expect(DeviceDirectTarget(id: "android:emulator-5554", platform: "android", kind: "emulator") == .androidEmulator(serial: "emulator-5554"))
        #expect(DeviceDirectTarget(id: "android:R5CT30ABCDE", platform: "android", kind: "physical") == nil)
        #expect(DeviceDirectTarget(id: "avd:Pixel_8", platform: "android", kind: "emulator") == nil)
    }

    @Test func deviceToolsGetAUTF8CharacterTypeUnlessALocaleIsSet() {
        // An app started from Finder: no locale at all (simctl pbcopy then wrote "café" as "caf√©").
        #expect(DeviceToolEnvironment.utf8(["PATH": "/usr/bin"]) == ["PATH": "/usr/bin", "LC_CTYPE": "UTF-8"])
        #expect(DeviceToolEnvironment.utf8(["LANG": ""])["LC_CTYPE"] == "UTF-8")
        // A locale the person set is kept as it is.
        #expect(DeviceToolEnvironment.utf8(["LANG": "ur_PK.UTF-8"]) == ["LANG": "ur_PK.UTF-8"])
        #expect(DeviceToolEnvironment.utf8(["LC_ALL": "en_GB.UTF-8"]) == ["LC_ALL": "en_GB.UTF-8"])
        #expect(DeviceToolEnvironment.utf8(["LC_CTYPE": "UTF-8", "X": "1"]) == ["LC_CTYPE": "UTF-8", "X": "1"])
    }

    @Test func onlyAFreshEventThePhoneDidNotTakeMovesTheKeyboard() {
        #expect(DeviceKeyboardClaim.isPersons(age: 0.01, phoneTookIt: false))
        #expect(DeviceKeyboardClaim.isPersons(age: 0.15, phoneTookIt: false))
        // A grab right after typing into the phone: the event is fresh but the phone's own.
        #expect(!DeviceKeyboardClaim.isPersons(age: 0.01, phoneTookIt: true))
        // A grab seconds after the last click: the event is stale.
        #expect(!DeviceKeyboardClaim.isPersons(age: 2, phoneTookIt: false))
        #expect(!DeviceKeyboardClaim.isPersons(age: .infinity, phoneTookIt: false))
        #expect(!DeviceKeyboardClaim.isPersons(age: .nan, phoneTookIt: false))
    }

    // "fix ai taps" (Asad, 22 Oct 2026): AI sessions' device tools take the panel's route.

    @Test func toolKeysHoldTheirModifiersOnce() {
        #expect(DeviceDirectKeys.named("return", modifiers: []) == [.init(40)])
        #expect(DeviceDirectKeys.named("return", modifiers: ["command", "shift"]) == [.init(40, modifiers: [227, 225])])
        #expect(DeviceDirectKeys.named("arrow-left", modifiers: ["option", "control"]) == [.init(80, modifiers: [226, 224])])
        // select-all already holds command: held once, not twice.
        #expect(DeviceDirectKeys.named("select-all", modifiers: ["command"]) == [.init(4, modifiers: [227])])
        #expect(DeviceDirectKeys.named("return", modifiers: ["hyper"]) == nil)
        #expect(DeviceDirectKeys.named("volume-up", modifiers: []) == nil)
    }

    @Test func untakenInputGoesToTheEngineOnTheSimulatorsOwnTouchscreen() {
        let inputs: [DeviceInput] = [.tap(x: 0.5, y: 0.5, holdMs: nil), .swipe(fromX: 0, fromY: 0, toX: 1, toY: 1, ms: 300),
                                     .key("return"), .button("back")]
        for input in inputs {
            #expect(DeviceToolDirect.untaken(input, coreDevice: false) == .engine)
            // On CoreDevice's touchscreen only the helper can reach it: refused in words instead.
            guard case .refused(let words) = DeviceToolDirect.untaken(input, coreDevice: true) else {
                Issue.record("\(input) was not refused"); continue
            }
            #expect(words.contains("Nothing was"))
            #expect(words.contains("CoreDevice"))
        }
    }

    /// 28 Oct 2026: Terminal Deck's own engine types any text through the simulator's pasteboard and ⌘V (a key the helper
    /// presses on either touchscreen), so typing the helper could not take is handed to it, never refused for its letters.
    @Test func untakenTypingGoesThroughThePasteboardOnEitherTouchscreen() {
        for text in ["caf\u{E9}", "hello", "p\u{E4}ssw0rd-s3cret", String(repeating: "a", count: 900)] {
            #expect(DeviceToolDirect.untaken(.type(text), coreDevice: false) == .engine)
            #expect(DeviceToolDirect.untaken(.type(text), coreDevice: true) == .engine)
        }
        #expect(DeviceDirectKeys.named("paste") == [.init(25, modifiers: [DeviceDirectKeys.leftCommand])])
    }

    @Test func sideButtonsGoToTheHelperWhenItHasThem() {
        let ready = SimDirectLine.ready("ready 1206 2622 touch=1 keys=1 buttons=1 side=1 core=1 hid=indigo")
        #expect(ready?.side == true)
        #expect(SimDirectLine.ready("ready 1206 2622 touch=1 keys=1 buttons=1 core=1 hid=indigo")?.side == false)
        for name in ["volume-up", "volume-down", "action"] {
            #expect(SimDirectLine.button(name, down: true, side: true) == "B \(name) d\n")
            #expect(SimDirectLine.button(name, down: true, side: false) == nil)
        }
        #expect(SimDirectLine.button("back", down: true, side: true) == nil)
    }

    @Test func longTypingGoesInPiecesWithinOneHelperWrite() {
        #expect(DeviceToolDirect.pieces("") == [])
        #expect(DeviceToolDirect.pieces("abc") == ["abc"])
        let text = String(repeating: "x", count: 450)
        #expect(DeviceToolDirect.pieces(text).map(\.count) == [200, 200, 50])
        #expect(DeviceToolDirect.pieces(text).joined() == text)
        // The worst piece (shifted symbols, four lines each) still fits the CoreDevice typing limit.
        let worst = String(repeating: "~", count: DeviceToolDirect.typingPiece)
        #expect(SimDirectLine.typing(worst, coreDevice: true) != nil)
    }

    // Review 22 Oct 2026: long AI typing writes its next piece only after the helper's echo for this one.
    @Test func eachTypingPieceWaitsForTheHelpersEcho() {
        #expect(SimDirectLine.echo(7) == "E 7\n")
        #expect(SimDirectLine.echoed("echo 7") == 7)
        #expect(SimDirectLine.echoed("echo") == nil)
        #expect(SimDirectLine.echoed("note echo 7") == nil)
        #expect(SimDirectLine.ready("echo 7") == nil)
        #expect(SimDirectLine.hid("echo 7") == nil)
        // 2,000 characters: ten pieces, each one helper write well inside a 16 KB pipe.
        let long = String(repeating: "Ab1~", count: 500)
        let parts = DeviceToolDirect.pieces(long)
        #expect(parts.count == 10)
        #expect(parts.allSatisfy { (SimDirectLine.typing($0, coreDevice: true)?.utf8.count ?? .max) < 16 * 1024 })
        #expect(DeviceToolDirect.pieceWithin >= 5)
    }

    // Review 22 Oct 2026: AI taps and swipes are in the turned app's frame (devices.tree); the helper turns them
    // onto the upright touchscreen. The panel's fingers are on the upright screen it shows.
    @Test func toolTouchesSayTheyAreInTheAppsFrame() {
        #expect(SimDirectLine.touch(down: true, [(0.25, 0.5)], appFrame: true) == "t 1 0.25000 0.50000\n")
        #expect(SimDirectLine.touch(down: false, [(0.25, 0.5)], appFrame: true) == "u 1 0.25000 0.50000\n")
        #expect(SimDirectLine.touch(down: true, [(0.25, 0.5)]) == "T 1 0.25000 0.50000\n")
        #expect(SimDirectLine.touch(down: true, [(2, -1)], appFrame: true) == "t 1 1.00000 0.00000\n")
    }

    @Test func theToolAnswersAfterTheInputHasPlayed() {
        #expect(DeviceToolDirect.duration(.tap(x: 0, y: 0, holdMs: nil)) == 100)
        #expect(DeviceToolDirect.duration(.tap(x: 0, y: 0, holdMs: 800)) == 830)
        #expect(DeviceToolDirect.duration(.swipe(fromX: 0, fromY: 0, toX: 1, toY: 1, ms: 300)) == 346)
        #expect(DeviceToolDirect.duration(.button("home")) == 110)
        #expect(DeviceToolDirect.duration(.type("hi")) == 50)
        #expect(SimDirectLine.inputOnly == "-")
        #expect(SimDirectLine.ready("ready 1 1 touch=1 keys=1 buttons=1 core=1 hid=coredevice")?.touchNow == true)
    }
}
