import XCTest
import Foundation
import TerminalDeckNativeCore

/// annotate.test.ts. Blocked (no Swift seam): browser `url` in describeWhere, `selector` on an element, roundForTools.
final class BackendFoundationTestsS6C5Annotate: XCTestCase {
    private static let box = NormRect(x: 0.04, y: 0.444, width: 0.92, height: 0.062)

    private func s6c5Round(note: String = "Make #1 bold and put #3 below it.\u{1b}[2J") -> AnnotationRound {
        var list = Annotation.adding([], id: "a", rect: Self.box,
            element: AnnotatedElement(role: "button", name: "General", identifier: "com.apple.settings.general"))
        list = Annotation.adding(list, id: "b", rect: NormRect(x: 0.5, y: 0.9, width: 0.04, height: 0.04), element: nil)
        list = Annotation.adding(list, id: "c", rect: NormRect(x: 0.04, y: 0.137, width: 0.33, height: 0.05),
            element: AnnotatedElement(role: "heading", name: "Settings", component: "Title",
                                      source: SourceLocation(file: "src/screens/Home.tsx", line: 42, column: 7)))
        return AnnotationRound(id: "r1", createdAt: 1_791_021_600_000,
            where_: AnnotateWhere(place: "iOS Simulator", name: "iPhone 17 Pro", deviceId: "ios:X", app: "com.example.Shop", screen: "Checkout"),
            frameWidth: 1206, frameHeight: 2622, annotations: list, note: note)
    }

    func testNumbersMarkersInTheOrderTheyWereAdded() {
        XCTAssertEqual(s6c5Round().annotations.map(\.n), [1, 2, 3])
    }

    func testClosesTheGapWhenOneIsDeleted() {
        let out = Annotation.removing(s6c5Round().annotations, id: "a")
        XCTAssertEqual(out.map(\.id), ["b", "c"])
        XCTAssertEqual(out.map(\.n), [1, 2])
    }

    func testOneNoteForTheRoundAndNoneOnTheMarkers() {
        let json = s6c5Round().json
        let markers = json["annotations"] as? [[String: Any]] ?? []
        XCTAssertEqual(markers.count, 3)
        for marker in markers { XCTAssertNil(marker["note"]) }
        XCTAssertNotNil(json["note"])
    }

    func testMessageIsOneLineWithNoControlCharacters() {
        let message = Handoff.composeRound(s6c5Round(), picturePath: "/Users/me/Pictures/App/iPhone-annotated.png")
        XCTAssertFalse(message.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f })
        XCTAssertEqual(Handoff.flat("a\nb\r\tc\u{1b}"), "a b c")
    }

    func testSaysWhereThenThePicture() {
        let message = Handoff.composeRound(s6c5Round(), picturePath: "/Users/me/Pictures/App/iPhone-annotated.png")
        XCTAssertTrue(message.hasPrefix("[Annotate: 3 marked elements on the iOS Simulator \"iPhone 17 Pro\", app com.example.Shop, screen Checkout;"))
        XCTAssertTrue(message.contains("picture with the numbered markers: /Users/me/Pictures/App/iPhone-annotated.png (1206 x 2622)]"))
    }

    func testListsEveryNumberedElementThenTheOneNote() {
        let message = Handoff.composeRound(s6c5Round(), picturePath: "/Users/me/Pictures/App/iPhone-annotated.png")
        let marked = "#1 button \"General\" (id com.apple.settings.general) at 4% across, 44% down, 92% x 6%; "
            + "#2 blank space at 50% across, 90% down, 4% x 4%; "
            + "#3 heading \"Settings\" (component Title, source src/screens/Home.tsx:42:7) at 4% across, 14% down, 33% x 5%."
        XCTAssertTrue(message.contains(marked))
        XCTAssertTrue(message.hasSuffix("What should change: Make #1 bold and put #3 below it. [2J"))
        let a = message.range(of: "#3 heading")!.lowerBound, b = message.range(of: "What should change")!.lowerBound
        XCTAssertLessThan(a, b)
    }

    func testSaysSoWhenThePictureCouldNotBeSaved() {
        XCTAssertTrue(Handoff.composeRound(s6c5Round(), picturePath: "").contains("the picture could not be saved"))
    }

    func testCountsOneElementAsOne() {
        var single = s6c5Round(note: "Bold.")
        single.annotations = Array(single.annotations.prefix(1))
        XCTAssertTrue(Handoff.composeRound(single, picturePath: "/p.png").contains("[Annotate: 1 marked element on "))
    }

    func testSaysBlankSpaceForAPointOnNothing() {
        XCTAssertEqual(Handoff.describeElement(nil), "blank space")
    }

    func testCutsAVeryLongNameRatherThanSendingAParagraph() {
        XCTAssertLessThan(Handoff.describeElement(AnnotatedElement(name: String(repeating: "x", count: 500))).count, 140)
    }
}
