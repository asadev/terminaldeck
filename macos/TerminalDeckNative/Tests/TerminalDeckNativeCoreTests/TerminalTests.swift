import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Lane T — the native session terminal's pure rules.

/// What JSONSerialization makes of a JSON text, as the engine bridge hands values over.
private func json(_ text: String) -> Any {
    try! JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

@Suite("Terminal backfill: history first, then live")
struct TerminalBackfillTests {
    @Test func holdsLiveOutputUntilTheHistoryIsIn() {
        var fill = TerminalBackfill()
        #expect(fill.isHolding)
        #expect(fill.push("live-1 ") == nil)
        #expect(fill.push("live-2 ") == nil)
        #expect(fill.release(backlog: "history ") == .init(history: "history ", live: "live-1 live-2 "))
        #expect(!fill.isHolding)
    }

    @Test func afterReleaseOutputIsWrittenAsItArrives() {
        var fill = TerminalBackfill()
        _ = fill.release(backlog: "old")
        #expect(fill.push("new") == "new")
    }

    @Test func releasingTwiceDoesNothingTheSecondTime() {
        var fill = TerminalBackfill()
        #expect(fill.release(backlog: nil)?.text == "")
        #expect(fill.release(backlog: "late history") == nil)
    }

    @Test func aReadThatNeverAnswersStillShowsTheLiveOutput() {
        var fill = TerminalBackfill()
        _ = fill.push("a")
        _ = fill.push("b")
        #expect(fill.release(backlog: nil) == .init(history: "", live: "ab"))
    }

    @Test func chunksAlreadyAtTheEndOfTheHistoryAreNotPrintedTwice() {
        var fill = TerminalBackfill()
        _ = fill.push("two ")
        _ = fill.push("three ")
        _ = fill.push("four ")
        // The read was taken after "two " and "three " were printed, before "four ".
        #expect(fill.release(backlog: "one two three ") == .init(history: "one two three ", live: "four "))
    }

    @Test func everyHeldChunkInTheHistoryLeavesOnlyTheHistory() {
        var fill = TerminalBackfill()
        _ = fill.push("b")
        _ = fill.push("c")
        #expect(fill.release(backlog: "abc") == .init(history: "abc", live: ""))
    }

    @Test func historyThatDoesNotEndWithTheHeldChunksKeepsThemAll() {
        var fill = TerminalBackfill()
        _ = fill.push("x")
        _ = fill.push("y")
        #expect(fill.release(backlog: "abc")?.text == "abcxy")
    }

    @Test func comparesBytesNotCharacters() {
        // "e" + combining acute arrives split from the base letter; a Character
        // comparison would see "é" and never match.
        var fill = TerminalBackfill()
        _ = fill.push("\u{301}")
        _ = fill.push("🙂")
        #expect(fill.release(backlog: "cafe\u{301}")?.text == "cafe\u{301}🙂")
    }

    @Test func emptyHistoryKeepsEveryHeldChunkInOrder() {
        var fill = TerminalBackfill()
        _ = fill.push("1")
        _ = fill.push("2")
        _ = fill.push("3")
        #expect(fill.release(backlog: "")?.text == "123")
    }

    @Test func holdLimitIsTheWebOnesTwoSeconds() {
        #expect(TerminalBackfill.holdLimit == 2)
    }
}

@Suite("Terminal drops and typed paths")
struct TerminalPathTests {
    @Test func posixPathIsSingleQuotedWithOneSpace() {
        #expect(TerminalText.promptWord("/Users/asad/My Photos/a.png") == "'/Users/asad/My Photos/a.png' ")
    }

    @Test func singleQuoteInsideIsClosedEscapedReopened() {
        #expect(TerminalText.shellQuote("/tmp/it's here") == "'/tmp/it'\\''s here'")
    }

    @Test func trailingSeparatorsGoButARootStays() {
        #expect(TerminalText.shellQuote("/Users/asad/project/") == "'/Users/asad/project'")
        #expect(TerminalText.shellQuote("/") == "'/'")
        #expect(TerminalText.shellQuote("C:\\") == "\"C:\\\"")
        #expect(TerminalText.shellQuote("C:\\\\") == "\"C:\\\"")
    }

    @Test func windowsPathsAreDoubleQuoted() {
        #expect(TerminalText.shellQuote("C:\\Users\\Asad\\a b.txt") == "\"C:\\Users\\Asad\\a b.txt\"")
        #expect(TerminalText.shellQuote("\\\\server\\share\\x") == "\"\\\\server\\share\\x\"")
    }

    @Test func whitespaceAroundIsTrimmed() {
        #expect(TerminalText.promptWord("  /tmp/a  ") == "'/tmp/a' ")
    }

    @Test func droppedTextLineEndsBecomeNewlines() {
        #expect(TerminalText.droppedText("one\r\ntwo\rthree\nfour") == "one\ntwo\nthree\nfour")
        #expect(TerminalText.droppedText("") == "")
    }

    @Test func fourDroppedFilesAreFourArguments() {
        let typed = ["/a", "/b c", "/d", "/e"].map(TerminalText.promptWord).joined()
        #expect(typed == "'/a' '/b c' '/d' '/e' ")
    }
}

@Suite("Terminal paste rules")
struct TerminalPasteTests {
    @Test func lineEndsBecomeReturnsAsXtermPastes() {
        #expect(TerminalText.pasteData("a\nb", bracketed: false) == "a\rb")
        #expect(TerminalText.pasteData("a\r\nb", bracketed: false) == "a\rb")
        #expect(TerminalText.pasteData("a\rb\r", bracketed: false) == "a\rb\r")
        #expect(TerminalText.pasteData("x\n\n", bracketed: false) == "x\r\r")
    }

    @Test func bracketedPasteWrapsTheWhole() {
        #expect(TerminalText.pasteData("ls\n", bracketed: true) == "\u{1b}[200~ls\r\u{1b}[201~")
    }

    @Test func filesCopiedInFinderAreTypedAsPaths() {
        // A Finder copy carries the file name as text and the icon as an image too.
        let plan = TerminalPastePlan.decide(filePaths: ["/Users/a/x.png", "/Users/a/y.txt"], hasImage: true,
                                            imageType: "image/png", text: "x.png", now: Date())
        #expect(plan == .paths(["/Users/a/x.png", "/Users/a/y.txt"]))
    }

    @Test func plainTextStaysAPlainTextPaste() {
        #expect(TerminalPastePlan.decide(filePaths: [], hasImage: false, imageType: nil, text: "git diff", now: Date())
                == .text("git diff"))
        // Text with an image beside it (a spreadsheet copy) pastes the image, as the page does.
        guard case .stageImage = TerminalPastePlan.decide(filePaths: [], hasImage: true, imageType: "image/png",
                                                          text: "a\tb", now: Date()) else {
            Issue.record("an image on the clipboard should win over its text")
            return
        }
    }

    @Test func aScreenshotIsStagedUnderATimestampedName() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_239_730) // 2026-10-05 22:35:30 UTC
        #expect(TerminalPastePlan.pastedName(type: "image/png", now: now, calendar: calendar) == "pasted-20261005-223530.png")
        #expect(TerminalPastePlan.pastedName(type: "image/jpeg", now: now, calendar: calendar).hasSuffix(".jpg"))
        #expect(TerminalPastePlan.pastedName(type: nil, now: now, calendar: calendar).hasSuffix(".bin"))
        let plan = TerminalPastePlan.decide(filePaths: [], hasImage: true, imageType: "image/png", text: nil, now: now)
        guard case .stageImage(let name) = plan else {
            Issue.record("expected an image to stage, got \(plan)")
            return
        }
        #expect(name.hasPrefix("pasted-") && name.hasSuffix(".png"))
    }

    @Test func nothingUsableIsNothing() {
        #expect(TerminalPastePlan.decide(filePaths: [""], hasImage: false, imageType: nil, text: "", now: Date()) == .nothing)
    }

    @Test func stagingAnswersAreReadLikeTheWebReadsThem() {
        #expect(TerminalHandover.read(json(#"{"ok":true,"path":"/Users/a/Library/x.png"}"#)) == .path("/Users/a/Library/x.png"))
        #expect(TerminalHandover.read(json(#"{"ok":false,"message":"Disk full."}"#)) == .refused("Disk full."))
        #expect(TerminalHandover.read(json(#"{"ok":true,"path":""}"#)) == .refused("That file did not send."))
        #expect(TerminalHandover.read(nil) == .refused("Sending files is not available in this build."))
    }

    @Test func aProgramMayCopyUpToAMegabyteAndNeverRead() {
        #expect(TerminalClipboard.decide(Data("token-123".utf8)) == .copy("token-123"))
        #expect(TerminalClipboard.decide(Data()) == .ignore)
        #expect(TerminalClipboard.decide(Data(count: TerminalClipboard.maxBytes + 1)) == .refuse(TerminalClipboard.tooLarge))
    }

    @Test func onlyWebAddressesOpen() {
        #expect(TerminalLinks.openable("https://example.com/a?b=c") == "https://example.com/a?b=c")
        #expect(TerminalLinks.openable("http://localhost:3000") == "http://localhost:3000")
        #expect(TerminalLinks.openable("file:///etc/passwd") == nil)
        #expect(TerminalLinks.openable("javascript:alert(1)") == nil)
        #expect(TerminalLinks.openable("/Users/asad/file.swift:12") == nil)
        #expect(TerminalLinks.openable("ssh://host") == nil)
    }

    @Test func chordsTakeCommandOrControlLikeThePage() {
        #expect(TerminalChord.from(key: "f", command: true, shift: false, option: false, control: false) == .find)
        #expect(TerminalChord.from(key: "F", command: true, shift: false, option: false, control: false) == .find)
        #expect(TerminalChord.from(key: "k", command: true, shift: true, option: false, control: false) == .clear)
        #expect(TerminalChord.from(key: "c", command: true, shift: true, option: false, control: false) == .copy)
        #expect(TerminalChord.from(key: "v", command: true, shift: false, option: false, control: false) == .paste)
        #expect(TerminalChord.from(key: "a", command: true, shift: false, option: false, control: false) == .selectAll)
        // The page's `terminalChord` takes ⌃ for its three: ⌃F, ⌃⇧K, ⌃⇧C.
        #expect(TerminalChord.from(key: "f", command: false, shift: false, option: false, control: true) == .find)
        #expect(TerminalChord.from(key: "K", command: false, shift: true, option: false, control: true) == .clear)
        #expect(TerminalChord.from(key: "c", command: false, shift: true, option: false, control: true) == .copy)
        // The Mac's edit chords stay ⌘ only: ⌃C, ⌃V and ⌃A belong to the program.
        #expect(TerminalChord.from(key: "c", command: false, shift: false, option: false, control: true) == nil)
        #expect(TerminalChord.from(key: "v", command: false, shift: false, option: false, control: true) == nil)
        #expect(TerminalChord.from(key: "a", command: false, shift: false, option: false, control: true) == nil)
        #expect(TerminalChord.from(key: "f", command: false, shift: false, option: false, control: false) == nil)
        #expect(TerminalChord.from(key: "f", command: true, shift: false, option: true, control: false) == nil)
        #expect(TerminalChord.from(key: "k", command: true, shift: false, option: false, control: false) == nil)
    }

    @Test func onlyLocalSessionsAreDrawnNatively() {
        #expect(TerminalSessionID.isLocal("3F2504E0-4F89-41D3-9A0C-0305E82C3301"))
        #expect(TerminalSessionID.isLocal("3f2504e0-4f89-41d3-9a0c-0305e82c3301"))
        #expect(!TerminalSessionID.isLocal("held:abc"))
        #expect(!TerminalSessionID.isLocal("machine m1 3f2504e0-4f89-41d3-9a0c-0305e82c3301"))
        #expect(!TerminalSessionID.isLocal("server s1 k1"))
        #expect(!TerminalSessionID.isLocal("browser:1759700000000:1"))
    }
}

@Suite("Terminal header model")
struct TerminalHeaderTests {
    private let list = json(#"""
    [
      {"id":"a","cwd":"/Users/asad/Projects/web/","title":"web","provider":"claude","exitCode":null,
       "createdAt":1,"profileId":"p1","profileName":"Work"},
      {"id":"b","cwd":"/tmp","title":"","provider":"shell","exitCode":2,"createdAt":2},
      {"id":"c","cwd":"/tmp","title":"x","provider":"codex","exitCode":true,"createdAt":3},
      {"cwd":"/no-id"}
    ]
    """#)

    @Test func decodesTheSessionRecord() throws {
        let a = try #require(TerminalSessionInfo.find("a", in: list))
        #expect(a.cwd == "/Users/asad/Projects/web/")
        #expect(a.folderName == "web")
        #expect(a.provider == "claude")
        #expect(a.agentName == "Claude Code")
        #expect(a.exitCode == nil)
        #expect(a.profileName == "Work")
        let b = try #require(TerminalSessionInfo.find("b", in: list))
        #expect(b.exitCode == 2)
        #expect(b.profileName == nil)
        #expect(b.agentName == "Shell")
        // A boolean is never an exit code.
        #expect(TerminalSessionInfo.find("c", in: list)?.exitCode == nil)
        #expect(TerminalSessionInfo.find("missing", in: list) == nil)
        #expect(TerminalSessionInfo.find("a", in: "not a list") == nil)
    }

    @Test func titleIsTheRailsNameThenTheSessionsThenTheFolder() {
        let a = TerminalSessionInfo.find("a", in: list)
        let b = TerminalSessionInfo.find("b", in: list)
        #expect(TerminalHeader.make(info: a, railTitle: "Session 2", status: .working, ended: false).title == "Session 2")
        #expect(TerminalHeader.make(info: a, railTitle: "  ", status: nil, ended: false).title == "web")
        #expect(TerminalHeader.make(info: b, railTitle: nil, status: nil, ended: false).title == "tmp")
        #expect(TerminalHeader.make(info: nil, railTitle: nil, status: nil, ended: false).title == "Session")
    }

    @Test func statusIsLiveUntilTheSessionEnds() {
        let a = TerminalSessionInfo.find("a", in: list)
        let running = TerminalHeader.make(info: a, railTitle: nil, status: .input, ended: false)
        #expect(running.status == .input)
        #expect(running.account == "Work")
        #expect(running.agent == "Claude Code")
        #expect(TerminalHeader.make(info: a, railTitle: nil, status: .working, ended: true).status == .exited)
        #expect(TerminalHeader.make(info: a, railTitle: nil, status: nil, ended: false).status == .idle)
    }

    @Test func statusWordsMatchTheWebDot() {
        #expect(TerminalStatus.parse("waiting")?.label == "Ready")
        #expect(TerminalStatus.parse("idle")?.label == "Ready")
        #expect(TerminalStatus.parse("input")?.label == "Needs input")
        #expect(TerminalStatus.parse("held") == nil)
        #expect(TerminalStatus.parse(3) == nil)
    }

    @Test func agentNames() {
        #expect(TerminalAgent.name("codex") == "Codex CLI")
        #expect(TerminalAgent.name("gemini") == "Gemini CLI")
        #expect(TerminalAgent.name("custom:open-code") == "Open Code")
    }

    @Test func controlsReadingDecodes() throws {
        let read = try #require(TerminalControls.decode(json(#"""
        {"model":{"value":"opus[1m]","label":"Opus 5 (1M context)","source":"screen"},
         "effort":{"value":"xhigh","label":"Extra high","source":"settings"},
         "fast":{"value":null,"label":null,"source":null},
         "permission":{"value":null,"label":null,"source":null},
         "live":true,"agent":{"running":true,"evidence":"screen"},
         "gate":{"canType":false,"reason":"Your draft is being carried."}}
        """#)))
        #expect(read.model.value == "opus[1m]")
        #expect(read.effort.label == "Extra high")
        #expect(read.live && read.agentRunning)
        #expect(!read.canType)
        #expect(read.blocked(read.model) == "Your draft is being carried.")
        #expect(read.shown(provider: "shell"))
        #expect(TerminalControls.decode("nope") == nil)
    }

    @Test func aForeignAgentSaysWhyItCannotBeChanged() throws {
        let read = try #require(TerminalControls.decode(json(#"""
        {"model":{"value":null,"label":null,"source":null,"unavailableReason":"Codex has its own /model."},
         "effort":{"value":null,"label":null,"source":null},
         "live":true,"agent":{"running":false},"gate":{"canType":true,"reason":null}}
        """#)))
        #expect(read.blocked(read.model) == "Codex has its own /model.")
        #expect(read.blocked(read.effort) == nil)
        #expect(!read.shown(provider: "shell"))
        #expect(read.shown(provider: "claude"))
    }

    @Test func applyAnswersDecode() {
        let ok = TerminalControlResult.decode(json(#"{"ok":true,"message":"Set model to Sonnet 5","reading":{"value":"sonnet","label":"Sonnet 5"}}"#))
        #expect(ok.ok && ok.message == "Set model to Sonnet 5" && ok.reading.value == "sonnet")
        let none = TerminalControlResult.decode(nil)
        #expect(!none.ok && none.message == "No answer from the session.")
    }

    @Test func modelLabelsAndTheTickedRow() {
        #expect(TerminalControlCatalog.shortModelLabel("Opus 5 with 1M context") == "Opus 5 1M")
        #expect(TerminalControlCatalog.shortModelLabel("Opus 5 (1M context) (default)") == "Opus 5 1M")
        #expect(TerminalControlCatalog.shortModelLabel("Opus in plan mode, else Sonnet") == "Opus Plan")
        #expect(TerminalControlCatalog.shortModelLabel("Sonnet 5") == "Sonnet 5")
        #expect(TerminalControlCatalog.shown(nil, model: true) == "Unknown")

        let onLong = TerminalControlReading(value: "x", label: "Opus 5 (1M context) (default)")
        let long = TerminalControlCatalog.models[0]
        let short = TerminalControlCatalog.models[1]
        #expect(TerminalControlCatalog.isCurrent(onLong, long))
        #expect(!TerminalControlCatalog.isCurrent(onLong, short))
        #expect(TerminalControlCatalog.isCurrent(TerminalControlReading(value: "opus", label: nil), short))
        #expect(!TerminalControlCatalog.isCurrent(TerminalControlReading(value: nil, label: "Opus 5"), short))
        #expect(TerminalControlCatalog.effort.map(\.id) == ["xhigh", "ultracode", "max", "high", "medium", "low", "auto"])
    }

    @Test func theEndedCardSaysWhatHappened() {
        let clean = TerminalEndNotice.exited(code: 0)
        #expect(clean.title == "This session has ended")
        #expect(clean.detail.hasPrefix("The program running here finished."))
        #expect(clean.actionLabel == "Start another session here")
        #expect(TerminalEndNotice.exited(code: nil) == clean)
        #expect(TerminalEndNotice.exited(code: 130).detail.hasPrefix("The program running here exited with status 130."))
        #expect(TerminalEndNotice.exitLine == "\r\n\u{1b}[2m[process exited]\u{1b}[0m\r\n")
    }
}

@Suite("Terminal settings and colours")
struct TerminalAppearanceTests {
    @Test func readsTheEnvelopeAndThePreferences() {
        let prefs = TerminalPreferences.from(
            settings: json(#"{"values":{"appearance.terminalFontSize":16,"appearance.terminalFontFamily":"JetBrains Mono, Menlo","general.copyOnSelect":true}}"#),
            prefs: json(#"{"theme":"light"}"#))
        #expect(prefs.fontSize == 16)
        #expect(prefs.fontCandidates == ["JetBrains Mono", "Menlo"])
        #expect(prefs.copyOnSelect)
        #expect(prefs.theme == .light)
    }

    @Test func aBareMapFromAnOlderBuildWorksToo() {
        let prefs = TerminalPreferences.from(settings: json(#"{"appearance.terminalFontSize":11}"#), prefs: nil)
        #expect(prefs.fontSize == 11)
        #expect(prefs.theme == .dark)
    }

    @Test func defaultsWhenNothingIsSet() {
        let prefs = TerminalPreferences.from(settings: nil, prefs: nil)
        #expect(prefs == TerminalPreferences())
        #expect(prefs.fontSize == 13 && prefs.fontFamily.isEmpty && !prefs.copyOnSelect)
        #expect(prefs.fontCandidates.isEmpty)
    }

    @Test func fontSizeIsClampedToWholeStepsLikeTheSchema() {
        #expect(TerminalPreferences.clampFontSize(30) == 24)
        #expect(TerminalPreferences.clampFontSize(2) == 9)
        #expect(TerminalPreferences.clampFontSize(12.4) == 12)
        #expect(TerminalPreferences.clampFontSize(.nan) == 13)
    }

    @Test func typesAreStrict() {
        // A boolean is not a size and a number is not a switch.
        let prefs = TerminalPreferences.from(
            settings: json(#"{"appearance.terminalFontSize":true,"general.copyOnSelect":1}"#), prefs: json(#"{"theme":"sepia"}"#))
        #expect(prefs.fontSize == 13)
        #expect(!prefs.copyOnSelect)
        #expect(prefs.theme == .dark)
    }

    @Test func followingTheAppTracksLightAndDark() {
        let follow = TerminalPreferences.from(settings: json(#"{"appearance.terminalScheme":"follow-app"}"#), prefs: json(#"{"theme":"system"}"#))
        #expect(follow.pinnedScheme == nil)
        #expect(follow.scheme(systemIsDark: true).id == "deck-dark")
        #expect(follow.scheme(systemIsDark: false).id == "deck-light")
        let light = TerminalPreferences(theme: .light)
        #expect(light.scheme(systemIsDark: true).id == "deck-light")
    }

    @Test func aPinnedSchemeIgnoresTheAppTheme() {
        let prefs = TerminalPreferences.from(settings: json(#"{"appearance.terminalScheme":"solarized-light"}"#), prefs: json(#"{"theme":"dark"}"#))
        #expect(prefs.scheme(systemIsDark: true).id == "solarized-light")
        #expect(prefs.scheme(systemIsDark: true).isLight)
    }

    @Test func aCustomSchemeIsReadFromItsOwnKeyAndWinsACollision() throws {
        var colours: [String: String] = ["name": "Mine", "background": "#000", "foreground": "#FFFFFF", "cursor": "#0af",
                                         "cursorAccent": "#000000", "selectionBackground": "#3b8fee29"]
        for slot in TerminalScheme.ansiSlots { colours[slot] = "#123456" }
        let stored = String(data: try JSONSerialization.data(withJSONObject: colours), encoding: .utf8)!
        let values: [String: Any] = ["appearance.terminalScheme": "nord", "appearance.terminalScheme.custom.nord": stored]
        let scheme = try #require(TerminalSchemes.pinned(in: values))
        #expect(scheme.name == "Mine")
        #expect(scheme.background == "#000000")
        #expect(scheme.foreground == "#ffffff")
        #expect(scheme.cursor == "#00aaff")
        #expect(scheme.ansi.count == 16)
    }

    @Test func aMissingOrBrokenSchemeFallsBackToFollowingTheApp() {
        #expect(TerminalSchemes.pinned(in: ["appearance.terminalScheme": "deleted-one"]) == nil)
        let broken: [String: Any] = ["appearance.terminalScheme": "mine",
                                     "appearance.terminalScheme.custom.mine": #"{"name":"Mine","background":"red"}"#]
        #expect(TerminalSchemes.pinned(in: broken) == nil)
        #expect(TerminalSchemes.customs(in: broken).isEmpty)
    }

    @Test func coloursAreNormalisedOrRefused() {
        #expect(TerminalColour.normalise("#ABC") == "#aabbcc")
        #expect(TerminalColour.normalise("#abcd") == "#aabbccdd")
        #expect(TerminalColour.normalise(" #3B8FEE29 ") == "#3b8fee29")
        #expect(TerminalColour.normalise("red") == nil)
        #expect(TerminalColour.normalise("#12345") == nil)
        let selection = TerminalColour(hex: "#3b8fee29")
        #expect(selection != nil && abs(selection!.alpha - 0x29 / 255.0) < 0.0001)
    }

    @Test func theBuiltInsAreTheWebOnes() {
        let ids = TerminalSchemes.builtins.map(\.id)
        #expect(ids.count == 13)
        #expect(Set(ids).count == ids.count)
        #expect(ids.prefix(2) == ["deck-dark", "deck-light"])
        let dark = TerminalSchemes.app(dark: true)
        #expect(dark.background == "#191919" && dark.foreground == "#ededed" && dark.cursor == "#3b8fee")
        #expect(dark.ansi[0] == "#2e3436" && dark.ansi[15] == "#eeeeec")
        #expect(TerminalSchemes.app(dark: false).background == "#e8e8e8")
        for scheme in TerminalSchemes.builtins {
            #expect(scheme.ansi.count == 16)
            for colour in [scheme.background, scheme.foreground, scheme.cursor, scheme.cursorAccent, scheme.selectionBackground] + scheme.ansi {
                #expect(TerminalColour.normalise(colour) == colour, "\(scheme.id): \(colour)")
            }
        }
    }
}
