import CoreGraphics
import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// Lane SIM: Inspect on the live screen, never freezing it — the debounce and
/// stale-drop of background tree reads, the frame-difference signal, hit-testing
/// over a tree at the live picture's scale, markers that outlive their screen,
/// and the one round that can carry several pictures.

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormRect {
    NormRect(x: x, y: y, width: w, height: h)
}

/// A small settings-like screen: a full-screen application, a heading, two named buttons.
private func screen(generalAt y: Double = 0.444) -> [DeviceNode] {
    let general = DeviceNode(ref: "ax:5", role: "AXButton", label: "General", identifier: "com.apple.settings.general",
                             frame: rect(0.04, y, 0.92, 0.062))
    let accessibility = DeviceNode(ref: "ax:6", role: "AXButton", label: "Accessibility", frame: rect(0.04, 0.506, 0.92, 0.062))
    let heading = DeviceNode(ref: "ax:1", role: "AXHeading", label: "Settings", frame: rect(0.04, 0.137, 0.331, 0.049))
    let root = DeviceNode(ref: "ax:0", role: "AXApplication", label: "Settings", frame: rect(0, 0, 1, 1),
                          children: [heading, general, accessibility])
    return DeviceTreeQuery.flatten(root)
}

// MARK: - Debounce and stale-drop

private func near(_ value: Double?, _ expected: Double) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 1e-9
}

struct LiveTreeScheduleTests {
    @Test func readsOnceTheScreenHasBeenQuietForTheSettleTime() {
        var schedule = LiveTreeSchedule()
        #expect(schedule.dueAt == nil)
        schedule.change(at: 10)
        #expect(near(schedule.dueAt, 10.4))
        schedule.change(at: 10.3)
        #expect(near(schedule.dueAt, 10.7))
        let r1 = schedule.begin(at: 10.5)
        #expect(r1 == nil)
        let token = schedule.begin(at: 10.71)
        #expect(token == LiveTreeSchedule.Token(generation: 2, startedAt: 10.71))
        #expect(schedule.isReading && schedule.dueAt == nil)
        let r2 = schedule.begin(at: 11)
        #expect(r2 == nil)
    }

    @Test func aScreenThatNeverSettlesIsStillReadEveryTwoSeconds() {
        var schedule = LiveTreeSchedule()
        var t = 0.0
        while t < 3 {
            schedule.change(at: t)
            t += 0.3
        }
        #expect(near(schedule.dueAt, 2.0))
    }

    @Test func dropsAnAnswerTheScreenMovedOnFrom() throws {
        var schedule = LiveTreeSchedule()
        schedule.request(at: 0)
        let r3 = schedule.begin(at: 0)
        let first = try #require(r3)
        let r4 = schedule.finish(first, at: 0.3)
        #expect(r4)
        #expect(schedule.isFresh)

        schedule.change(at: 1)
        let r5 = schedule.begin(at: 1.4)
        let second = try #require(r5)
        schedule.change(at: 1.5) // a scroll began while it was being read
        #expect(!schedule.isFresh)
        let r101 = schedule.finish(second, at: 1.8)
        #expect(!r101)
        #expect(schedule.shown == first)
        // The newer change already has the next read due.
        #expect(near(schedule.dueAt, 1.9))
        let r6 = schedule.begin(at: 1.9)
        let third = try #require(r6)
        let r7 = schedule.finish(third, at: 2.2)
        #expect(r7)
        #expect(schedule.isFresh)
    }

    @Test func takesAStaleAnswerWhenNothingOrSomethingTooOldIsShown() throws {
        var schedule = LiveTreeSchedule()
        schedule.request(at: 0)
        let r8 = schedule.begin(at: 0)
        let first = try #require(r8)
        schedule.change(at: 0.1)
        let r9 = schedule.finish(first, at: 0.5)
        #expect(r9) // nothing on show: better than none
        #expect(!schedule.isFresh)

        let r10 = schedule.begin(at: 2.6)
        let second = try #require(r10)
        schedule.change(at: 2.7)
        let r11 = schedule.finish(second, at: 3.0)
        #expect(r11) // on show for 2.5 s already
        #expect(schedule.shown == second)
    }

    @Test func aReadFromBeforeInspectWasTurnedOffIsLetGo() throws {
        var schedule = LiveTreeSchedule()
        schedule.request(at: 0)
        let r12 = schedule.begin(at: 0)
        let token = try #require(r12)
        schedule.reset()
        let r102 = schedule.finish(token, at: 0.2)
        #expect(!r102)
        #expect(schedule.shown == nil && !schedule.isReading)
    }

    @Test func aFailedReadWaitsForTheNextChangeOrReadAgain() throws {
        var schedule = LiveTreeSchedule()
        schedule.request(at: 0)
        let r13 = schedule.begin(at: 0)
        let token = try #require(r13)
        schedule.fail(token)
        #expect(!schedule.isReading && schedule.dueAt == nil)
        schedule.request(at: 5)
        #expect(schedule.dueAt == 5)
    }
}

// MARK: - The frame-difference signal

struct ScreenSignatureTests {
    @Test func samplesTheCentreOfEveryCell() throws {
        var seen: [String] = []
        let signature = try #require(ScreenSignature.sample(width: 100, height: 40, columns: 2, rows: 2) { x, y in
            seen.append("\(x),\(y)")
            return UInt8(x)
        })
        #expect(seen == ["25,10", "75,10", "25,30", "75,30"])
        #expect(signature.samples == [25, 75, 25, 75])
        #expect(ScreenSignature.sample(width: 0, height: 10) { _, _ in 0 } == nil)
    }

    @Test func aCaretBlinkIsNotAChangeButAScrollIs() throws {
        let still = try #require(ScreenSignature.sample(width: 1206, height: 2622) { _, _ in 200 })
        var caret = still
        caret.samples[500] = 0
        #expect(!caret.differs(from: still))
        var scrolled = still
        for index in 0..<(scrolled.samples.count / 10) { scrolled.samples[index] = 20 }
        #expect(scrolled.differs(from: still))
        var noise = still
        for index in noise.samples.indices { noise.samples[index] = 210 } // within the step: compression noise
        #expect(!noise.differs(from: still))
        #expect(ScreenSignature(columns: 1, rows: 1, samples: [0]).differs(from: still))
    }

    @Test func aSlowFadeAddsUpAgainstTheLastChange() {
        var detector = ScreenChangeDetector()
        func frame(_ level: UInt8) -> ScreenSignature { ScreenSignature(columns: 4, rows: 4, samples: Array(repeating: level, count: 16)) }
        let r103 = detector.observe(frame(100))
        #expect(!r103)      // the first frame only sets the reference
        let r104 = detector.observe(frame(110))
        #expect(!r104)
        let r105 = detector.observe(frame(120))
        #expect(!r105)
        let r14 = detector.observe(frame(130))
        #expect(r14)       // 30 from the reference
        let r106 = detector.observe(frame(140))
        #expect(!r106)      // the reference moved to 130
        detector.reset()
        let r107 = detector.observe(frame(0))
        #expect(!r107)
    }
}

// MARK: - Hit-testing at the live picture's scale

struct LiveHitTestTests {
    @Test func findsTheElementUnderThePointerOnASmallerLivePicture() throws {
        // The tree was read against the full 1206 × 2622 screenshot; the video is half that.
        let video = CGSize(width: 603, height: 1311)
        let fitted = DeviceGeometry.fitted(content: video, in: CGSize(width: 800, height: 900))
        let onGeneral = CGPoint(x: fitted.minX + 0.5 * fitted.width, y: fitted.minY + 0.47 * fitted.height)
        let at = try #require(DeviceGeometry.normalizedInside(onGeneral, in: fitted))
        let node = LiveInspect.elementAt(CGPoint(x: at.x, y: at.y), in: screen(),
                                         treePicture: CGSize(width: 1206, height: 2622), video: video)
        #expect(node?.ref == "ax:5")
        // The letterbox beside the phone is not part of it.
        #expect(DeviceGeometry.normalizedInside(CGPoint(x: fitted.minX - 5, y: fitted.midY), in: fitted) == nil)
    }

    @Test func aTurnedPictureIsNotHitTestedWithTheUprightTree() {
        let node = LiveInspect.elementAt(CGPoint(x: 0.5, y: 0.47), in: screen(),
                                         treePicture: CGSize(width: 1206, height: 2622), video: CGSize(width: 2622, height: 1206))
        #expect(node == nil)
        #expect(LiveInspect.sameShape(CGSize(width: 1206, height: 2622), CGSize(width: 600, height: 1306)))
        #expect(!LiveInspect.sameShape(CGSize(width: 1206, height: 2622), .zero))
    }
}

// MARK: - Markers that survive screen changes

struct LiveMarkerTests {
    @Test func findsTheElementAgainByIdentifierWhereverItMoved() throws {
        let general = try #require(screen().first { $0.ref == "ax:5" })
        let markers = LiveMarkers.adding([], id: "m1", node: general, rect: rect(0, 0, 0, 0), picture: 3)
        #expect(markers[0].annotation.rect == general.frame)
        #expect(markers[0].annotation.element?.identifier == "com.apple.settings.general")
        #expect(markers[0].node?.children.isEmpty == true)
        // Scrolled up, and given another ref by the new reading.
        var moved = screen(generalAt: 0.3)
        moved = moved.map { node in
            var copy = node
            if copy.ref == "ax:5" { copy.ref = "ax:42" }
            return copy
        }
        let hit = LiveMarkers.match(markers[0], in: moved)
        #expect(hit?.ref == "ax:42")
        let placed = LiveMarkers.placements(markers, nodes: moved, fresh: true, generation: 9)
        #expect(placed.first?.rect == rect(0.04, 0.3, 0.92, 0.062))
        #expect(placed.first?.ref == "ax:42")
    }

    @Test func withoutAnIdentifierItMatchesByRefOrByPlace() throws {
        let accessibility = try #require(screen().first { $0.ref == "ax:6" })
        let marker = LiveMarkers.adding([], id: "m", node: accessibility, rect: rect(0, 0, 0, 0), picture: 1)[0]
        #expect(LiveMarkers.match(marker, in: screen())?.ref == "ax:6")
        // Same role, name and place under a new ref.
        let renamedRef = screen().map { node -> DeviceNode in
            var copy = node
            if copy.ref == "ax:6" { copy.ref = "ax:60" }
            return copy
        }
        #expect(LiveMarkers.match(marker, in: renamedRef)?.ref == "ax:60")
        // The same ref now on a different element of another screen: not it.
        let other = [DeviceNode(ref: "ax:6", role: "AXStaticText", label: "Wi-Fi", frame: rect(0.1, 0.7, 0.5, 0.04))]
        #expect(LiveMarkers.match(marker, in: other) == nil)
        // Gone from the screen: stays in the side list, not drawn.
        #expect(LiveMarkers.placements([marker], nodes: other, fresh: true, generation: 1).isEmpty)
    }

    @Test func nothingIsDrawnFromATreeTheScreenMovedOnFrom() throws {
        let general = try #require(screen().first { $0.ref == "ax:5" })
        let markers = LiveMarkers.adding([], id: "m", node: general, rect: rect(0, 0, 0, 0), picture: 1)
        #expect(LiveMarkers.placements(markers, nodes: screen(), fresh: false, generation: 2).isEmpty)
        #expect(LiveMarkers.placements(markers, nodes: nil, fresh: true, generation: 1).isEmpty)
    }

    @Test func aMarkByPositionStaysOnlyOnTheScreenItWasMadeOn() {
        let markers = LiveMarkers.adding([], id: "p", node: nil, rect: rect(0.5, 0.9, 0.04, 0.04), picture: 4)
        #expect(markers[0].annotation.element == nil)
        #expect(LiveMarkers.placements(markers, nodes: nil, fresh: false, generation: 4).count == 1)
        #expect(LiveMarkers.placements(markers, nodes: screen(), fresh: true, generation: 5).isEmpty)
    }

    @Test func aMarkMadeWhileTheScreenWasBeingReadBecomesItsElement() {
        let point = DeviceGeometry.boxAround(x: 0.5, y: 0.47)
        var markers = LiveMarkers.adding([], id: "w", node: nil, rect: point, picture: 7, awaitingElement: true)
        markers = LiveMarkers.adding(markers, id: "old", node: nil, rect: point, picture: 6, awaitingElement: true)
        // A reading of an earlier screen changes nothing yet.
        let early = LiveMarkers.upgrading(markers, nodes: screen(), generation: 5, treePicture: CGSize(width: 1, height: 2), video: nil)
        #expect(early == markers)
        let read = LiveMarkers.upgrading(markers, nodes: screen(), generation: 7, treePicture: CGSize(width: 1, height: 2), video: nil)
        #expect(read[0].annotation.element?.name == "General")
        #expect(read[0].annotation.nodeRef == "ax:5")
        #expect(read[0].annotation.rect == rect(0.04, 0.444, 0.92, 0.062))
        #expect(!read[0].awaitingElement)
        // Made on screen 6, read only on 7: the screen it was on is gone, it stays a mark by position.
        #expect(read[1].annotation.element == nil && !read[1].awaitingElement)
        // A deliberate click on blank space never waits.
        #expect(!LiveMarkers.adding([], id: "b", node: screen()[1], rect: point, picture: 1, awaitingElement: true)[0].awaitingElement)
    }

    @Test func removingRenumbersAndPicturesGroupInOrder() throws {
        let nodes = screen()
        var markers = LiveMarkers.adding([], id: "a", node: nodes[2], rect: rect(0, 0, 0, 0), picture: 2)
        markers = LiveMarkers.adding(markers, id: "b", node: nil, rect: rect(0.1, 0.1, 0.04, 0.04), picture: 5)
        markers = LiveMarkers.adding(markers, id: "c", node: nodes[1], rect: rect(0, 0, 0, 0), picture: 2)
        markers = LiveMarkers.adding(markers, id: "d", node: nil, rect: rect(0.2, 0.2, 0.04, 0.04), picture: 5)
        let groups = LiveMarkers.pictureGroups(markers)
        #expect(groups.map(\.picture) == [2, 5])
        #expect(groups[0].markers.map(\.n) == [1, 3])
        #expect(groups[1].markers.map(\.n) == [2, 4])
        let fewer = LiveMarkers.removing(markers, id: "b")
        #expect(fewer.map(\.n) == [1, 2, 3])
        #expect(fewer.map(\.id) == ["a", "c", "d"])
    }
}

// MARK: - One round, several pictures

struct LiveRoundTests {
    func round() -> AnnotationRound {
        var list = Annotation.adding([], id: "a", rect: rect(0.04, 0.444, 0.92, 0.062),
                                     element: AnnotatedElement(role: "button", name: "General", identifier: "com.apple.settings.general"))
        list = Annotation.adding(list, id: "b", rect: rect(0.5, 0.9, 0.04, 0.04), element: nil)
        list = Annotation.adding(list, id: "c", rect: rect(0.1, 0.2, 0.3, 0.05), element: AnnotatedElement(role: "switch", name: "Wi-Fi"))
        return AnnotationRound(id: "r1", createdAt: 1_791_021_600_000,
                               where_: AnnotateWhere(place: "iOS Simulator", name: "iPhone 17 Pro", deviceId: "ios:X",
                                                     app: "com.apple.Preferences", screen: "Settings"),
                               frameWidth: 603, frameHeight: 1311, annotations: list, note: "Fix #1 and #3.")
    }

    @Test func onePictureIsTheSameMessageAsBefore() {
        let pictures = [RoundPicture(path: "/p/one.png", width: 603, height: 1311, markers: [1, 2, 3])]
        #expect(Handoff.composeRound(round(), pictures: pictures) == Handoff.composeRound(round(), picturePath: "/p/one.png"))
        #expect(Handoff.composeRound(round(), pictures: []) == Handoff.composeRound(round(), picturePath: ""))
    }

    @Test func severalPicturesAreNamedInTheOneMessage() {
        let pictures = [RoundPicture(path: "/p/one.png", width: 603, height: 1311, markers: [1, 2], screen: "Settings"),
                        RoundPicture(path: "/p/two.png", width: 603, height: 1311, markers: [3], screen: "Wi-Fi")]
        let message = Handoff.composeRound(round(), pictures: pictures)
        #expect(message.hasPrefix("[Annotate: 3 marked elements on the iOS Simulator \"iPhone 17 Pro\", app com.apple.Preferences, screen Settings; "
            + "2 pictures with the numbered markers: /p/one.png (603 x 1311) showing #1, #2; /p/two.png (603 x 1311) showing #3, screen Wi-Fi] "))
        #expect(message.contains("#1 button \"General\" (id com.apple.settings.general) at 4% across, 44% down, 92% x 6%; #2 blank space"))
        #expect(message.hasSuffix(" What should change: Fix #1 and #3."))
        #expect(!message.contains("\n"))
    }

    @Test func theRoundJSONListsThePicturesOnlyWhenThereAreSeveral() throws {
        let one = round().json(pictures: [RoundPicture(path: "/p/one.png", width: 603, height: 1311, markers: [1, 2, 3])])
        #expect(one["pictures"] == nil)
        #expect(NSDictionary(dictionary: one).isEqual(to: round().json))

        let pictures = [RoundPicture(path: "", width: 603, height: 1311, markers: [1, 2], screen: "Settings"),
                        RoundPicture(path: "/p/two.png", width: 1311, height: 603, markers: [3])]
        let several = round().json(pictures: pictures)
        let listed = try #require(several["pictures"] as? [[String: Any]])
        #expect(listed.count == 2)
        #expect(listed[0]["path"] == nil) // the round's own picture, being saved with it
        #expect(listed[0]["markers"] as? [Int] == [1, 2])
        #expect(listed[0]["screen"] as? String == "Settings")
        #expect(listed[1]["path"] as? String == "/p/two.png")
        #expect(listed[1]["width"] as? Int == 1311)
        // Everything a reader of one picture knows is still there, unchanged.
        for key in ["id", "createdAt", "where", "frame", "note", "annotations"] { #expect(several[key] != nil) }
        #expect((several["annotations"] as? [[String: Any]])?.count == 3)
        #expect(JSONSerialization.isValidJSONObject(several))
    }
}
