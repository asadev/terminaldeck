import Foundation
import Testing
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Lane SIM: a round whose markers came from several live screens still reads
/// as a round in `annotate:save` (`BackendAppDeviceParsing.round`): the added
/// `pictures` list is left out and everything a one-picture reader knows is kept.
struct SIMRoundReadableTests {
    @Test func aSeveralPictureRoundIsReadByAnnotateSave() throws {
        var list = Annotation.adding([], id: "a", rect: NormRect(x: 0.04, y: 0.444, width: 0.92, height: 0.062),
                                     element: AnnotatedElement(role: "button", name: "General", identifier: "com.apple.settings.general"))
        list = Annotation.adding(list, id: "b", rect: NormRect(x: 0.5, y: 0.9, width: 0.04, height: 0.04), element: nil)
        let round = AnnotationRound(id: "round-1", createdAt: 1_791_021_600_000,
                                    where_: AnnotateWhere(place: "iOS Simulator", name: "iPhone 17 Pro", deviceId: "ios:X", screen: "Settings"),
                                    frameWidth: 603, frameHeight: 1311, annotations: list, note: "Fix #1.")
        let pictures = [RoundPicture(path: "", width: 603, height: 1311, markers: [1]),
                        RoundPicture(path: "/p/two.png", width: 603, height: 1311, markers: [2], screen: "Wi-Fi")]
        let read = BackendAppDeviceParsing.round(try NativeRPCValue.fromFoundation(round.json(pictures: pictures)))
        #expect(read["id"].string == "round-1")
        #expect(read["where"]["screen"].string == "Settings")
        #expect(read["frame"]["width"].number == 603)
        #expect(read["note"].string == "Fix #1.")
        let annotations = try #require(read["annotations"].elements)
        #expect(annotations.count == 2)
        #expect(annotations[0]["element"]["identifier"].string == "com.apple.settings.general")
        #expect(annotations[1]["element"].isNullish)
        #expect(annotations[1]["n"].number == 2)
        #expect(read["pictures"].isNullish)
    }
}
