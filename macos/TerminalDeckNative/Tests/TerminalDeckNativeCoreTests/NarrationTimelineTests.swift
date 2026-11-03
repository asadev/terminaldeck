import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// Lane NARR: live narration of a phone recording — segments by screen, tagging,
/// editing, and the two send payloads (talk while recording / plain video).
@Suite struct NarrationTimelineTests {
    private func words(_ text: String, at start: Double, step: Double = 0.3) -> [NarrationWord] {
        text.split(separator: " ").enumerated().map { index, token in
            NarrationWord(start: start + Double(index) * step, end: start + Double(index + 1) * step, text: String(token))
        }
    }

    @Test func wordsGoToTheScreenOnShowWhenTheyWereSaid() {
        var timeline = NarrationTimeline()
        timeline.begin(name: "Home", keyframe: "/k/1.png")
        timeline.heard(final: words("this is the home list", at: 0.5))
        #expect(timeline.newScreen(at: 4, name: "Listing details", keyframe: "/k/2.png") == 2)
        timeline.heard(final: words("the price is cut off", at: 4.4))
        #expect(timeline.newScreen(at: 9, name: "Checkout", keyframe: "/k/3.png") == 3)
        timeline.heard(volatile: words("pay button too small", at: 9.5))
        timeline.finish(at: 12)

        #expect(timeline.segments.map(\.title) == ["Home", "Listing details", "Checkout"])
        #expect(timeline.text(of: 1) == "this is the home list")
        #expect(timeline.text(of: 2) == "the price is cut off")
        #expect(timeline.text(of: 3) == "pay button too small")
        #expect(timeline.segments.map(\.end) == [4, 9, 12])
        #expect(timeline.volatile.isEmpty)
    }

    @Test func aPhraseThatStartedBeforeTheChangeSplitsAtTheChange() {
        var timeline = NarrationTimeline()
        timeline.begin(name: "A")
        timeline.newScreen(at: 2, name: "B")
        // "one two three four" said 1.4 … 2.6: the first two before B appeared.
        timeline.heard(final: words("one two three four", at: 1.4))
        #expect(timeline.text(of: 1) == "one two")
        #expect(timeline.text(of: 2) == "three four")
    }

    @Test func aScreenPassedThroughIsReplacedNotAdded() {
        var timeline = NarrationTimeline()
        timeline.begin(name: "Home")
        timeline.heard(final: words("start here", at: 0.2))
        timeline.newScreen(at: 3, name: "Loading", keyframe: "/k/loading.png")
        timeline.newScreen(at: 3.4, name: "Profile", keyframe: "/k/profile.png")
        #expect(timeline.segments.count == 2)
        #expect(timeline.segments[1].title == "Profile")
        #expect(timeline.segments[1].keyframe == "/k/profile.png")
        #expect(timeline.segments[1].start == 3)
    }

    @Test func aShortScreenWithWordsOnItIsKept() {
        var timeline = NarrationTimeline()
        timeline.begin(name: "Home")
        timeline.newScreen(at: 3, name: "Sheet")
        timeline.heard(final: words("look", at: 3.1))
        timeline.newScreen(at: 3.5, name: "Home")
        #expect(timeline.segments.map(\.title) == ["Home", "Sheet", "Home"])
    }

    @Test func volatileWordsAreReplacedThenSettled() {
        var timeline = NarrationTimeline()
        timeline.begin()
        timeline.heard(volatile: words("the bottom", at: 1))
        #expect(timeline.caption() == "the bottom")
        timeline.heard(volatile: words("the button", at: 1))
        #expect(timeline.caption() == "the button")
        timeline.heard(final: words("the button is grey.", at: 1), from: 1, to: 2.5)
        #expect(timeline.volatile.isEmpty)
        #expect(timeline.caption() == "the button is grey.")
    }

    @Test func wordsBeforeTheVideoStartedCountForTheFirstScreen() {
        var timeline = NarrationTimeline()
        timeline.begin(name: "Home")
        timeline.heard(final: [NarrationWord(start: -0.4, end: -0.1, text: "Okay")] + words("so", at: 0.1))
        #expect(timeline.text(of: 1) == "Okay so")
    }

    @Test func theTagSaysTheScreenAndHowLongItHasBeenOnShow() {
        var timeline = NarrationTimeline()
        timeline.begin()
        #expect(timeline.tag(now: 5) == "Screen 1 · 0:05")
        timeline.newScreen(at: 8, name: "Listing details")
        #expect(timeline.tag(now: 20.7) == "Listing details · 0:12")
        timeline.name(2, nil)
        #expect(timeline.tag(now: 75) == "Screen 2 · 1:07")
    }

    @Test func editingASegmentKeepsHisWordsAndCanBeUndone() {
        var timeline = NarrationTimeline()
        timeline.begin(name: "Home")
        timeline.heard(final: words("the pay button is grey", at: 0))
        timeline.edit(1, text: "The Pay button should be green.")
        #expect(timeline.text(of: 1) == "The Pay button should be green.")
        #expect(timeline.segments[0].edited != nil)
        timeline.edit(1, text: "the pay button is grey")
        #expect(timeline.segments[0].edited == nil)
        timeline.edit(1, text: "")
        #expect(timeline.text(of: 1) == "")
    }

    @Test func joiningKeepsPunctuationTight() {
        let joined = NarrationWord.join([.init(start: 0, end: 0, text: "Hello"), .init(start: 0, end: 0, text: ","),
                                         .init(start: 0, end: 0, text: "world"), .init(start: 0, end: 0, text: "."),
                                         .init(start: 0, end: 0, text: " ")])
        #expect(joined == "Hello, world.")
        let spread = NarrationWord.spread("one two three four", from: 10, to: 12)
        #expect(spread.map(\.start) == [10, 10.5, 11, 11.5])
    }

    // MARK: Screen changes

    private func signature(_ fill: (Int, Int) -> UInt8) -> ScreenSignature {
        var samples: [UInt8] = []
        for row in 0..<ScreenSignature.rows { for column in 0..<ScreenSignature.columns { samples.append(fill(row, column)) } }
        return ScreenSignature(columns: ScreenSignature.columns, rows: ScreenSignature.rows, samples: samples)
    }

    @Test func aScrollUnderAFixedTitleIsNotANewScreen() {
        let before = signature { row, _ in UInt8((row * 37) % 255) }
        // Rows below the title band moved (a scroll); the top 18% stayed.
        let scrolled = signature { row, _ in row < 9 ? UInt8((row * 37) % 255) : UInt8(((row + 5) * 37) % 255) }
        #expect(NarrationScreenChange.isCandidate(from: before, to: scrolled))
        #expect(!NarrationScreenChange.isNewScreen(from: before, to: scrolled, anchorName: nil, nowName: nil))
        // With names: the same title means the same screen whatever the picture did.
        #expect(!NarrationScreenChange.isNewScreen(from: before, to: scrolled, anchorName: "Inbox", nowName: "inbox "))
    }

    @Test func aNewTitleOrAWholeNewPictureIsANewScreen() {
        let before = signature { row, _ in UInt8((row * 37) % 255) }
        let pushed = signature { row, column in UInt8((row * 37 + column * 11 + 128) % 255) }
        #expect(NarrationScreenChange.isNewScreen(from: before, to: pushed, anchorName: nil, nowName: nil))
        #expect(NarrationScreenChange.isNewScreen(from: before, to: before, anchorName: "Inbox", nowName: "Message"))
        let caret = signature { row, column in row == 30 && column == 3 ? 255 : UInt8((row * 37) % 255) }
        #expect(!NarrationScreenChange.isCandidate(from: before, to: caret))
    }

    // MARK: The screen's name

    @Test func theNameComesFromTheNavigationBarThenAHeadingThenTopText() {
        let bar = DeviceNode(ref: "root", role: "AXApplication", children: [
            DeviceNode(ref: "time", role: "AXStaticText", label: "9:41", frame: NormRect(x: 0.05, y: 0.01, width: 0.1, height: 0.02)),
            DeviceNode(ref: "nav", role: "AXNavigationBar", children: [
                DeviceNode(ref: "back", role: "AXButton", label: "Back", frame: NormRect(x: 0, y: 0.06, width: 0.2, height: 0.04)),
                DeviceNode(ref: "title", role: "AXStaticText", label: "Listing details", frame: NormRect(x: 0.3, y: 0.06, width: 0.4, height: 0.04)),
            ]),
        ])
        #expect(NarrationScreenName.name(root: bar) == "Listing details")

        let heading = DeviceNode(ref: "root", role: "android.widget.FrameLayout", children: [
            DeviceNode(ref: "h", role: "heading", label: "Checkout", frame: NormRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05)),
        ])
        #expect(NarrationScreenName.name(root: heading) == "Checkout")

        let plain = DeviceNode(ref: "root", role: "android.widget.FrameLayout", children: [
            DeviceNode(ref: "clock", role: "android.widget.TextView", text: "12:30", frame: NormRect(x: 0, y: 0.06, width: 0.1, height: 0.02)),
            DeviceNode(ref: "t", role: "android.widget.TextView", text: "Settings", frame: NormRect(x: 0.1, y: 0.08, width: 0.5, height: 0.05)),
            DeviceNode(ref: "low", role: "android.widget.TextView", text: "Wi-Fi", frame: NormRect(x: 0.1, y: 0.5, width: 0.5, height: 0.05)),
        ])
        #expect(NarrationScreenName.name(root: plain) == "Settings")
        #expect(NarrationScreenName.name(root: plain, reported: "MainActivity") == "MainActivity")
        #expect(NarrationScreenName.name(root: nil) == nil)
    }

    // MARK: What Send says

    @Test func talkWhileRecordingSendsAPictureAndWordsPerScreen() {
        var timeline = NarrationTimeline()
        timeline.begin(name: "Home", keyframe: "/p/screen-01.png")
        timeline.heard(final: words("the list looks fine", at: 0.5))
        timeline.newScreen(at: 12, name: "Listing details", keyframe: "/p/screen-02.png")
        timeline.heard(final: words("price is cut off", at: 13))
        timeline.newScreen(at: 30, name: nil, keyframe: nil)
        timeline.finish(at: 42)
        timeline.edit(2, text: "The price is cut off\non the right.")

        let screens = NarrationPayload.screens(timeline)
        let message = NarrationPayload.narrated(screens: screens, videoPath: "/p/simulator-recording.mp4", seconds: 42,
                                                kind: "iOS Simulator", deviceName: "iPhone 17 Pro", note: "Fix  these\nplease")
        let lines = message.components(separatedBy: "\n")
        #expect(lines == [
            "Fix these please",
            "[iOS Simulator walkthrough of \"iPhone 17 Pro\": 3 screens over 0:42, a picture of each screen with what I said on it. The video is kept at /p/simulator-recording.mp4]",
            "Screen 1 \"Home\" (0:00–0:12, picture: /p/screen-01.png): the list looks fine",
            "Screen 2 \"Listing details\" (0:12–0:30, picture: /p/screen-02.png): The price is cut off on the right.",
            "Screen 3 \"Screen 3\" (0:30–0:42, no picture): (nothing said)",
        ])
        #expect(NarrationPayload.summary(narrated: true, screens: 3, seconds: 42) == "3 screens with your words")
        #expect(NarrationPayload.summary(narrated: true, screens: 1, seconds: 42) == "1 screen with your words")
    }

    @Test func aPlainRecordingSendsTheVideoAsItIs() {
        let message = NarrationPayload.plain(videoPath: "/p/simulator-recording.mp4", width: 1206, height: 2622, seconds: 42.04,
                                             kind: "Android emulator", deviceName: "Pixel 8", note: "")
        #expect(message == "[Android emulator screen recording of \"Pixel 8\": /p/simulator-recording.mp4 (1206 x 2622, 42.0 s)]")
        let noted = NarrationPayload.plain(videoPath: "/v.mp4", width: 2, height: 2, seconds: 1, kind: "iOS Simulator",
                                           deviceName: "", note: "Watch the spinner")
        #expect(noted == "Watch the spinner [iOS Simulator screen recording: /v.mp4 (2 x 2, 1.0 s)]")
        #expect(NarrationPayload.summary(narrated: false, screens: 0, seconds: 42.9) == "Video, 0:42")
    }

    // MARK: Phrases for a key provider

    @Test func phrasesEndAtAPauseOrAtTheLongest() {
        var cutter = NarrationPhraseCutter(threshold: 0.1, pause: 0.6, longest: 5)
        var cuts: [ClosedRange<Double>] = []
        var t = 0.0
        func feed(_ level: Float, seconds: Double) {
            var left = seconds
            while left > 0.001 {
                if let cut = cutter.feed(level: level, from: t, to: t + 0.1) { cuts.append(cut) }
                t += 0.1; left -= 0.1
            }
        }
        feed(0, seconds: 1)          // silence alone: nothing
        feed(0.5, seconds: 1)        // speech…
        feed(0, seconds: 0.8)        // …a pause ends it
        #expect(cuts.count == 1)
        feed(0.5, seconds: 6)        // a long run is cut at 5 s
        #expect(cuts.count == 2)
        #expect(abs(cuts[1].upperBound - cuts[1].lowerBound - 5) < 0.11)
        feed(0.5, seconds: 0.5)
        #expect(cutter.flush(at: t) != nil)
    }
}
