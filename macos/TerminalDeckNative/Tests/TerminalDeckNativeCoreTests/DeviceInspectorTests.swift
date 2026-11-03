import CoreGraphics
import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// The native Simulators screen's pure logic: the element under a point, the
/// quick checks, view ↔ device coordinates, the message a session receives,
/// the stream's packets, and input ordering. The cases that mirror the web
/// page's own tests (`device-tree.test.ts`, `annotate.test.ts`) assert the same
/// answers, so the native inspector and the page cannot disagree.

/// The Settings screen of a real iOS 27 simulator, as `device-tree.test.ts` has it, in the bridge's JSON.
nonisolated(unsafe) private let settingsJSON: [String: Any] = [
    "ref": "ax:0", "role": "AXApplication", "label": "Settings",
    "frame": ["normalized": ["x": 0, "y": 0, "width": 1, "height": 1]],
    "children": [
        ["ref": "ax:1", "role": "AXHeading", "label": "Settings",
         "frame": ["normalized": ["x": 0.04, "y": 0.137, "width": 0.331, "height": 0.049]]],
        ["ref": "ax:2", "role": "AXGroup", "identifier": "com.apple.settings.sidebar.collectionView",
         "frame": ["normalized": ["x": 0, "y": 0, "width": 1, "height": 1]],
         "children": [
            ["ref": "ax:5", "role": "AXButton", "label": "General", "identifier": "com.apple.settings.general",
             "frame": ["normalized": ["x": 0.04, "y": 0.444, "width": 0.92, "height": 0.062]],
             "children": [
                ["ref": "ax:5a", "role": "AXImage", "frame": ["normalized": ["x": 0.06, "y": 0.455, "width": 0.06, "height": 0.03]]],
             ]],
            ["ref": "ax:6", "role": "AXButton", "label": "Accessibility", "identifier": "com.apple.settings.accessibility",
             "frame": ["normalized": ["x": 0.04, "y": 0.506, "width": 0.92, "height": 0.062]]],
            ["ref": "ax:7", "role": "AXButton", "label": "Hidden one", "hidden": true,
             "frame": ["normalized": ["x": 0.04, "y": 0.6, "width": 0.92, "height": 0.062]]],
         ] as [Any]],
    ] as [Any],
]

private func settings() throws -> DeviceNode { try #require(DeviceNode.read(settingsJSON)) }

@Suite("Element at a point")
struct ElementAtPointTests {
    @Test func isTheSmallestNamedElementNotTheScreen() throws {
        #expect(DeviceTreeQuery.elementAt(try settings(), x: 0.5, y: 0.475)?.label == "General")
    }

    @Test func isTheButtonNotTheUnlabelledPictureInsideIt() throws {
        #expect(DeviceTreeQuery.elementAt(try settings(), x: 0.08, y: 0.47)?.label == "General")
    }

    @Test func fallsBackToWhateverHoldsThePoint() throws {
        // Blank space: only scaffolding covers it, and the answer still says where.
        #expect(DeviceTreeQuery.elementAt(try settings(), x: 0.9, y: 0.3) != nil)
    }

    @Test func neverPicksAHiddenElement() throws {
        #expect(DeviceTreeQuery.elementAt(try settings(), x: 0.5, y: 0.63)?.label != "Hidden one")
    }

    @Test func nothingOutsideEveryFrame() {
        let small = DeviceNode(ref: "a", label: "A", frame: NormRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        #expect(DeviceTreeQuery.elementAt(small, x: 0.9, y: 0.9) == nil)
    }

    @Test func readsTheBridgeJSONFaithfully() throws {
        let root = try settings()
        #expect(DeviceTreeQuery.flatten(root).map(\.ref) == ["ax:0", "ax:1", "ax:2", "ax:5", "ax:5a", "ax:6", "ax:7"])
        let general = try #require(DeviceTreeQuery.node(ref: "ax:5", in: root))
        #expect(general.frame == NormRect(x: 0.04, y: 0.444, width: 0.92, height: 0.062))
        #expect(general.identifier == "com.apple.settings.general")
        #expect(DeviceTreeQuery.node(ref: "ax:7", in: root)?.hidden == true)
    }

    @Test func givesEveryNodeAUniqueRefAndDropsARedactedValue() throws {
        let json: [String: Any] = ["ref": "x", "children": [
            ["role": "AXSecureTextField", "value": "hunter2", "valueRedacted": true],
            ["ref": "x"],
        ] as [Any]]
        let root = try #require(DeviceNode.read(json))
        let refs = DeviceTreeQuery.flatten(root).map(\.ref)
        #expect(Set(refs).count == refs.count)
        #expect(root.children[0].value == nil && root.children[0].valueRedacted)
    }

    @Test func readsATreeThatIsNotATreeWithoutHanging() {
        var node = DeviceNode(ref: "leaf")
        for i in 0..<400 { node = DeviceNode(ref: "x\(i)", children: [node]) }
        #expect(DeviceTreeQuery.flatten(node).count <= 202)
    }

    @Test func saysRolesAndNamesAsAPersonWould() {
        #expect(DeviceTreeQuery.plainRole("AXButton") == "button")
        #expect(DeviceTreeQuery.plainRole("AXTextField") == "text field")
        #expect(DeviceTreeQuery.plainRole("android.widget.TextView") == "text view")
        #expect(DeviceTreeQuery.plainRole(nil) == "")
        #expect(DeviceTreeQuery.nodeName(DeviceNode(ref: "a", label: "Pay", identifier: "pay-button")) == "Pay")
        #expect(DeviceTreeQuery.nodeName(DeviceNode(ref: "a", identifier: "pay-button")) == "pay-button")
    }

    @Test func outlineOpensToAnElement() throws {
        let root = try settings()
        #expect(DeviceTreeQuery.ancestors(of: "ax:5a", in: root) == ["ax:0", "ax:2", "ax:5"])
        #expect(DeviceTreeQuery.ancestors(of: "nope", in: root).isEmpty)
        let closed = DeviceTreeQuery.outlineRows(root, expanded: [])
        #expect(closed.map(\.node.ref) == ["ax:0"])
        let open = DeviceTreeQuery.outlineRows(root, expanded: ["ax:0", "ax:2"])
        #expect(open.map(\.node.ref) == ["ax:0", "ax:1", "ax:2", "ax:5", "ax:6", "ax:7"])
        #expect(open.first { $0.node.ref == "ax:5" }?.depth == 2)
    }
}

@Suite("Quick checks")
struct QuickCheckTests {
    /// A 402 × 874 pt iPhone screen.
    let points = CGSize(width: 402, height: 874)

    func screen(_ children: [DeviceNode]) -> DeviceNode {
        DeviceNode(ref: "root", role: "AXApplication", label: "App", frame: NormRect(x: 0, y: 0, width: 1, height: 1), children: children)
    }

    @Test func findsAButtonWithNoLabel() {
        let icon = DeviceNode(ref: "b", role: "AXButton", identifier: "close-button",
                              frame: NormRect(x: 0.8, y: 0.05, width: 0.15, height: 0.07))
        let findings = DeviceChecks.run(screen([icon]), points: points)
        #expect(findings == [DeviceFinding(kind: .missingLabel, ref: "b", role: "button", what: "close-button")])
        #expect(findings[0].sentence(minimum: 44, unit: "pt") == "A button with no label (close-button)")
    }

    @Test func aLabelledFieldOrOneWithHintTextIsNotMissingALabel() {
        let field = DeviceNode(ref: "f", role: "AXTextField", placeholder: "Email",
                               frame: NormRect(x: 0.05, y: 0.3, width: 0.9, height: 0.06))
        let label = DeviceNode(ref: "l", role: "AXButton", label: "Save", frame: NormRect(x: 0.05, y: 0.5, width: 0.9, height: 0.06))
        #expect(DeviceChecks.run(screen([field, label]), points: points).isEmpty)
    }

    @Test func findsATapTargetUnder44Points() throws {
        // 0.06 × 402 = 24.1 pt wide, 0.03 × 874 = 26.2 pt tall.
        let tiny = DeviceNode(ref: "t", role: "AXButton", label: "Info", frame: NormRect(x: 0.5, y: 0.5, width: 0.06, height: 0.03))
        let findings = DeviceChecks.run(screen([tiny]), points: points)
        let finding = try #require(findings.first)
        guard case let .smallTarget(width, height) = finding.kind else {
            Issue.record("expected a size finding"); return
        }
        #expect(abs(width - 24.12) < 0.01 && abs(height - 26.22) < 0.01)
        #expect(finding.sentence(minimum: 44, unit: "pt") == "button \"Info\" is 24 × 26 pt, under 44 × 44")
    }

    @Test func aTargetOfExactly44PointsPasses() {
        let ok = DeviceNode(ref: "o", role: "AXButton", label: "OK",
                            frame: NormRect(x: 0.1, y: 0.1, width: 44.0 / 402, height: 44.0 / 874))
        #expect(DeviceChecks.run(screen([ok]), points: points).isEmpty)
    }

    @Test func skipsHiddenOffScreenAndNonInteractiveElements() {
        let hidden = DeviceNode(ref: "h", role: "AXButton", hidden: true, frame: NormRect(x: 0.1, y: 0.1, width: 0.01, height: 0.01))
        let away = DeviceNode(ref: "a", role: "AXButton", frame: NormRect(x: 0.1, y: 1.2, width: 0.01, height: 0.01))
        let text = DeviceNode(ref: "s", role: "AXStaticText", frame: NormRect(x: 0.1, y: 0.1, width: 0.01, height: 0.01))
        #expect(DeviceChecks.run(screen([hidden, away, text]), points: points).isEmpty)
    }

    @Test func withoutPointsOnlyLabelsAreChecked() {
        let tiny = DeviceNode(ref: "t", role: "AXButton", frame: NormRect(x: 0.5, y: 0.5, width: 0.01, height: 0.01))
        #expect(DeviceChecks.run(screen([tiny]), points: nil).map(\.kind) == [.missingLabel])
    }

    @Test func androidAsksFor48dp() {
        #expect(DeviceChecks.minimumTarget(platform: "android") == 48)
        #expect(DeviceChecks.minimumTarget(platform: "ios") == 44)
        // 46 dp: fine on iOS's 44, small on Android's 48.
        let button = DeviceNode(ref: "b", role: "android.widget.Button", text: "Go",
                                frame: NormRect(x: 0.1, y: 0.1, width: 46.0 / 400, height: 46.0 / 800))
        let size = CGSize(width: 400, height: 800)
        #expect(DeviceChecks.run(screen([button]), points: size, minimum: 44).isEmpty)
        #expect(DeviceChecks.run(screen([button]), points: size, minimum: 48).count == 1)
    }

    @Test func labelsComeBeforeSizes() throws {
        let unnamedSmall = DeviceNode(ref: "u", role: "AXButton", frame: NormRect(x: 0.1, y: 0.1, width: 0.02, height: 0.02))
        let findings = DeviceChecks.run(screen([unnamedSmall]), points: points)
        #expect(findings.map(\.kind.isLabel) == [true, false])
    }
}

private extension DeviceFinding.Kind {
    var isLabel: Bool { self == .missingLabel }
}

@Suite("View and device coordinates")
struct CoordinateTests {
    @Test func fitsAPhoneInAWideViewCentred() {
        let fitted = DeviceGeometry.fitted(content: CGSize(width: 1206, height: 2622), in: CGSize(width: 1000, height: 1311))
        #expect(fitted == CGRect(x: 198.5, y: 0, width: 603, height: 1311))
    }

    @Test func fitsAWidePictureInATallViewCentred() {
        let fitted = DeviceGeometry.fitted(content: CGSize(width: 200, height: 100), in: CGSize(width: 100, height: 300))
        #expect(fitted == CGRect(x: 0, y: 125, width: 100, height: 50))
    }

    @Test func nothingFitsInNothing() {
        #expect(DeviceGeometry.fitted(content: .zero, in: CGSize(width: 10, height: 10)) == .zero)
        #expect(DeviceGeometry.normalized(.zero, in: .zero) == nil)
    }

    @Test func aViewPointBecomesANormalisedPoint() throws {
        let fitted = CGRect(x: 100, y: 0, width: 400, height: 800)
        let centre = try #require(DeviceGeometry.normalized(CGPoint(x: 300, y: 400), in: fitted))
        #expect(centre.x == 0.5 && centre.y == 0.5)
        let corner = try #require(DeviceGeometry.normalized(CGPoint(x: 100, y: 0), in: fitted))
        #expect(corner.x == 0 && corner.y == 0)
    }

    @Test func aPointInTheLetterboxIsClampedForInputAndIgnoredForHover() throws {
        let fitted = CGRect(x: 100, y: 0, width: 400, height: 800)
        let clamped = try #require(DeviceGeometry.normalized(CGPoint(x: 20, y: 900), in: fitted))
        #expect(clamped.x == 0 && clamped.y == 1)
        #expect(DeviceGeometry.normalizedInside(CGPoint(x: 20, y: 400), in: fitted) == nil)
        #expect(DeviceGeometry.normalizedInside(CGPoint(x: 120, y: 400), in: fitted) != nil)
    }

    @Test func aNormalisedFrameLandsOnTheViewAndBack() throws {
        let fitted = DeviceGeometry.fitted(content: CGSize(width: 1206, height: 2622), in: CGSize(width: 1000, height: 1311))
        let general = NormRect(x: 0.04, y: 0.444, width: 0.92, height: 0.062)
        let box = DeviceGeometry.viewRect(general, in: fitted)
        #expect(abs(box.minX - (198.5 + 0.04 * 603)) < 1e-9)
        #expect(abs(box.minY - 0.444 * 1311) < 1e-9)
        #expect(abs(box.width - 0.92 * 603) < 1e-9)
        let back = try #require(DeviceGeometry.normalized(CGPoint(x: box.midX, y: box.midY), in: fitted))
        #expect(abs(back.x - 0.5) < 1e-9 && abs(back.y - 0.475) < 1e-9)
        // And that point is the button the page would pick.
        #expect(DeviceTreeQuery.elementAt(try settings(), x: back.x, y: back.y)?.label == "General")
    }

    @Test func pointsFollowTheWayUpThePictureIs() {
        #expect(DeviceGeometry.screenPoints(pointWidth: 402, pointHeight: 874, pictureWidth: 1206, pictureHeight: 2622)
                == CGSize(width: 402, height: 874))
        #expect(DeviceGeometry.screenPoints(pointWidth: 402, pointHeight: 874, pictureWidth: 2622, pictureHeight: 1206)
                == CGSize(width: 874, height: 402))
        #expect(DeviceGeometry.screenPoints(pointWidth: 0, pointHeight: 874, pictureWidth: 1, pictureHeight: 2) == nil)
    }

    @Test func markersAreSizedToThePictureAndKeptOnIt() {
        let rect = NormRect(x: 0.04, y: 0.444, width: 0.92, height: 0.062)
        let phone = MarkerGeometry(rect: rect, width: 1206, height: 2622)
        let small = MarkerGeometry(rect: rect, width: 402, height: 874)
        #expect(phone.stroke > small.stroke && phone.badgeRadius > small.badgeRadius)
        #expect(abs(phone.box.minX - 48.24) < 0.001)
        let top = MarkerGeometry(rect: NormRect(x: 0, y: 0, width: 1, height: 0.05), width: 1206, height: 2622)
        #expect(top.badgeCentre.x - top.badgeRadius > 0 && top.badgeCentre.y - top.badgeRadius > 0)
    }

    @Test func aMarkOnBlankSpaceIsABoxAroundThePoint() {
        #expect(DeviceGeometry.boxAround(x: 0.5, y: 0.5) == NormRect(x: 0.48, y: 0.48, width: 0.04, height: 0.04))
        #expect(DeviceGeometry.boxAround(x: 0, y: 1) == NormRect(x: 0, y: 0.96, width: 0.04, height: 0.04))
    }
}

@Suite("What a session receives")
struct SendPayloadTests {
    func round(note: String = "Make #1 bold and put #3 below it.\u{1b}[2J") -> AnnotationRound {
        var list = Annotation.adding([], id: "a", rect: NormRect(x: 0.04, y: 0.444, width: 0.92, height: 0.062),
                                     element: AnnotatedElement(role: "button", name: "General", identifier: "com.apple.settings.general"))
        list = Annotation.adding(list, id: "b", rect: NormRect(x: 0.5, y: 0.9, width: 0.04, height: 0.04), element: nil)
        list = Annotation.adding(list, id: "c", rect: NormRect(x: 0.04, y: 0.137, width: 0.33, height: 0.05),
                                 element: AnnotatedElement(role: "heading", name: "Settings", component: "Title",
                                                           source: SourceLocation(file: "src/screens/Home.tsx", line: 42, column: 7)))
        return AnnotationRound(id: "r1", createdAt: 1_791_021_600_000,
                               where_: AnnotateWhere(place: "iOS Simulator", name: "iPhone 17 Pro", deviceId: "ios:X",
                                                     app: "com.example.Shop", screen: "Checkout"),
                               frameWidth: 1206, frameHeight: 2622, annotations: list, note: note)
    }

    @Test func isTheSameLineThePageSends() {
        let message = Handoff.composeRound(round(), picturePath: "/Users/me/Pictures/App/iPhone-annotated.png")
        #expect(message.hasPrefix("[Annotate: 3 marked elements on the iOS Simulator \"iPhone 17 Pro\", app com.example.Shop, screen Checkout;"))
        #expect(message.contains("picture with the numbered markers: /Users/me/Pictures/App/iPhone-annotated.png (1206 x 2622)]"))
        let marked = "#1 button \"General\" (id com.apple.settings.general) at 4% across, 44% down, 92% x 6%; "
            + "#2 blank space at 50% across, 90% down, 4% x 4%; "
            + "#3 heading \"Settings\" (component Title, source src/screens/Home.tsx:42:7) at 4% across, 14% down, 33% x 5%."
        #expect(message.contains(marked))
        #expect(message.hasSuffix("What should change: Make #1 bold and put #3 below it. [2J"))
    }

    @Test func isOneLineWithNoControlCharacters() {
        let message = Handoff.composeRound(round(note: "line one\nline two\t\u{7f}end"), picturePath: "/p.png")
        #expect(!message.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
        #expect(Handoff.flat("a\nb\r\tc\u{1b}") == "a b c")
    }

    @Test func saysWhenThePictureCouldNotBeSaved() {
        #expect(Handoff.composeRound(round(), picturePath: "").contains("the picture could not be saved"))
    }

    @Test func countsOneElementAsOne() {
        var single = round(note: "Bold.")
        single.annotations = Array(single.annotations.prefix(1))
        #expect(Handoff.composeRound(single, picturePath: "/p.png").contains("[Annotate: 1 marked element on "))
    }

    @Test func recordsATreeNodeWithoutRepeatingANameAsAnId() {
        let general = AnnotatedElement(node: DeviceNode(ref: "x", role: "AXButton", label: "General", identifier: "com.apple.settings.general"))
        #expect(general == AnnotatedElement(role: "button", name: "General", identifier: "com.apple.settings.general"))
        let save = AnnotatedElement(node: DeviceNode(ref: "y", role: "AXButton", identifier: "save"))
        #expect(save == AnnotatedElement(role: "button", identifier: "save"))
    }

    @Test func theSavedRoundIsTheShapeTheEngineReads() throws {
        let json = round().json
        #expect(json["id"] as? String == "r1")
        #expect(json["note"] as? String == "Make #1 bold and put #3 below it.\u{1b}[2J")
        let frame = try #require(json["frame"] as? [String: Any])
        #expect(frame["width"] as? Int == 1206 && frame["height"] as? Int == 2622)
        let place = try #require(json["where"] as? [String: Any])
        #expect(place["kind"] as? String == "device" && place["app"] as? String == "com.example.Shop")
        let markers = try #require(json["annotations"] as? [[String: Any]])
        #expect(markers.map { $0["n"] as? Int } == [1, 2, 3])
        #expect(markers[1]["element"] is NSNull)
        let source = try #require((markers[2]["element"] as? [String: Any])?["source"] as? [String: Any])
        #expect(source["line"] as? Int == 42)
        // It crosses the bridge as JSON.
        #expect(JSONSerialization.isValidJSONObject(json))
    }

    @Test func removingAMarkerRenumbersTheRest() {
        let left = Annotation.removing(round().annotations, id: "a")
        #expect(left.map { [$0.id, String($0.n)] } == [["b", "1"], ["c", "2"]])
    }

    @Test func aScreenshotIsOneLineNamingTheDevice() {
        let line = Handoff.composeScreenshot(path: "/far/x.png", width: 1206, height: 2622, kind: "iOS Simulator",
                                             deviceName: "iPhone\n17", instruction: "Look")
        #expect(line == "Look [iOS Simulator screenshot of \"iPhone 17\": /far/x.png (1206 x 2622)]")
        #expect(Handoff.composeScreenshot(path: "/x.png", width: 1, height: 2, kind: "Android phone", deviceName: "", instruction: " ")
                == "[Android phone screenshot: /x.png (1 x 2)]")
    }

    @Test func isTypedThenSubmittedAsTwoWrites() {
        #expect(Handoff.terminalWrites("  hello  ") == ["hello", "\r"])
        // A mention menu would eat the Return without the space.
        #expect(Handoff.terminalWrites("see @file") == ["see @file ", "\r"])
        #expect(Handoff.terminalWrites(" \n ").isEmpty)
    }

    @Test func sessionsAreNumberedPerFolderAndCalledByTheirName() {
        let list: [Any] = [
            ["id": "s1", "cwd": "/Users/a/shop", "title": "shop", "provider": "claude", "exitCode": NSNull()],
            ["id": "s2", "cwd": "/Users/a/shop", "title": "Checkout fixes", "provider": "codex", "exitCode": NSNull()],
            ["id": "s3", "cwd": "/Users/a/shop", "title": "shop", "provider": "claude", "exitCode": 0],
            ["id": "s4", "cwd": "", "title": "", "provider": "claude", "exitCode": NSNull()],
            ["cwd": "/no/id"],
        ]
        let rows = AgentSessions.read(list)
        #expect(rows.map(\.label) == ["shop · Session 1", "Checkout fixes", "shop · Session 3", "Session 1"])
        #expect(rows.map(\.ended) == [false, false, true, false])
        #expect(AgentSessions.resolve("s1", in: rows)?.id == "s1")
        #expect(AgentSessions.resolve("s3", in: rows) == nil)
        #expect(AgentSessions.resolve("", in: rows) == nil)
        #expect(AgentSessions.whyDisabled("", in: rows) == "")
        #expect(AgentSessions.whyDisabled("s3", in: rows) == "shop · Session 3 has exited. Choose another one.")
        #expect(AgentSessions.whyDisabled("gone", in: rows) == "That session is gone. Choose another one.")
        #expect(AgentSessions.whyDisabled("", in: []) == "No sessions are open. Start one, then choose it here.")
    }

    @Test func twoSessionsWithOneNameAreToldApart() {
        let rows = AgentSessions.read([
            ["id": "a", "cwd": "/x/one", "title": "Fixer", "exitCode": NSNull()],
            ["id": "b", "cwd": "/x/two", "title": "Fixer", "exitCode": NSNull()],
        ] as [Any])
        #expect(rows.map(\.label) == ["Fixer — one · Session 1", "Fixer — two · Session 1"])
    }
}

@Suite("The live stream's packets")
struct StreamPacketTests {
    /// A real avcC record (High profile, level 3.0, 4-byte lengths) from VideoToolbox, trimmed to one SPS and one PPS.
    let avcC = Data([0x01, 0x64, 0x00, 0x1E, 0xFF, 0xE1, 0x00, 0x04, 0x67, 0x64, 0x00, 0x1E,
                     0x01, 0x00, 0x03, 0x68, 0xEE, 0x3C])

    @Test func readsTheDecoderConfiguration() throws {
        let config = try #require(AVCConfiguration(avcC: avcC))
        #expect(config.codec == "avc1.64001e")
        #expect(config.nalLengthSize == 4)
        #expect(config.sequenceParameterSets == [Data([0x67, 0x64, 0x00, 0x1E])])
        #expect(config.pictureParameterSets == [Data([0x68, 0xEE, 0x3C])])
        #expect(config.parameterSets.count == 2)
    }

    @Test func refusesABrokenConfiguration() {
        #expect(AVCConfiguration(avcC: Data([0x01, 0x64])) == nil)
        #expect(AVCConfiguration(avcC: Data([0x02] + avcC.dropFirst())) == nil)
        #expect(AVCConfiguration(avcC: avcC.prefix(10)) == nil)
    }

    @Test func readsAPictureTimestampKeyFlagAndData() throws {
        var packet = Data([0x11, 0, 0, 0, 0, 0, 0x01, 0x02, 0x03, 1])
        packet.append(contentsOf: [0, 0, 0, 2, 0x65, 0x88])
        // Sliced, as the event stream hands out views into larger buffers.
        let sliced = (Data([0xAA]) + packet).dropFirst()
        guard case let .picture(timestamp, key, data)? = ScreenPacket(sliced) else {
            Issue.record("expected a picture"); return
        }
        #expect(timestamp == 0x010203)
        #expect(key)
        #expect(data == Data([0, 0, 0, 2, 0x65, 0x88]))
    }

    @Test func tellsTheKindsApart() {
        #expect(ScreenPacket(Data([0x10]) + avcC) == .config(avcC))
        #expect(ScreenPacket(Data([0x12, 0xFF, 0xD8])) == .jpeg(Data([0xFF, 0xD8])))
        #expect(ScreenPacket(Data([0x20, 0x89, 0x50])) == .still(Data([0x89, 0x50])))
        #expect(ScreenPacket(Data([0x11, 0, 0])) == nil)
        #expect(ScreenPacket(Data([0x55, 1])) == nil)
        #expect(ScreenPacket(Data()) == nil)
    }
}

@Suite("Input and the engine's answers")
struct DeviceInputTests {
    @Test func movesWaitingToGoAreFoldedIntoTheNewestNeverAnythingElse() {
        var queue = DeviceInputQueue()
        queue.push(.touch(phase: "down", x: 0.1, y: 0.1))
        queue.push(.touch(phase: "move", x: 0.2, y: 0.2))
        queue.push(.touch(phase: "move", x: 0.3, y: 0.3))
        queue.push(.touch(phase: "move", x: 0.4, y: 0.4))
        queue.push(.touch(phase: "up", x: 0.4, y: 0.4))
        queue.push(.type("a"))
        queue.push(.type("b"))
        var order: [DeviceInput] = []
        while let next = queue.next() { order.append(next) }
        #expect(order == [.touch(phase: "down", x: 0.1, y: 0.1), .touch(phase: "move", x: 0.4, y: 0.4),
                          .touch(phase: "up", x: 0.4, y: 0.4), .type("a"), .type("b")])
    }

    @Test func goesOutOnThePagesChannels() {
        let tap = DeviceInput.tap(x: 0.5, y: 0.25, holdMs: nil).call(device: "ios:A")
        #expect(tap.channel == "devices:tap" && tap.args.count == 4 && tap.args[3] == nil)
        let swipe = DeviceInput.swipe(fromX: 0.5, fromY: 0.5, toX: 0.5, toY: 0.2, ms: 220).call(device: "ios:A")
        #expect(swipe.channel == "devices:swipe")
        #expect((swipe.args[2] as? [String: Double]) == ["x": 0.5, "y": 0.2])
        #expect(DeviceInput.key("return").call(device: "ios:A").channel == "devices:key")
        #expect(DeviceInput.button("home").call(device: "ios:A").channel == "devices:button")
        #expect(DeviceInput.touch(phase: "down", x: 0, y: 1).call(device: "ios:A").args[1] as? String == "down")
    }

    @Test func aPressWithoutAFingerIsATapALongPressOrASwipe() {
        #expect(DeviceGesture.release(fromX: 0.1, fromY: 0.2, toX: 0.1, toY: 0.2, moved: false, heldMs: 120) == .tap(x: 0.1, y: 0.2, holdMs: nil))
        #expect(DeviceGesture.release(fromX: 0.1, fromY: 0.2, toX: 0.1, toY: 0.2, moved: false, heldMs: 800) == .tap(x: 0.1, y: 0.2, holdMs: 800))
        #expect(DeviceGesture.release(fromX: 0.1, fromY: 0.2, toX: 0.1, toY: 0.8, moved: true, heldMs: 40)
                == .swipe(fromX: 0.1, fromY: 0.2, toX: 0.1, toY: 0.8, ms: 150))
    }

    @Test func theWheelScrollsAsAShortSwipeAgainstIt() {
        // Further down the page is a finger moving up the glass.
        #expect(DeviceGesture.wheel(dx: 0, dy: 225) == .swipe(fromX: 0.5, fromY: 0.5, toX: 0.5, toY: 0.25, ms: 220))
        // A big flick is held to a short swipe.
        guard case let .swipe(_, _, _, toY, _)? = DeviceGesture.wheel(dx: 0, dy: 90_000) else {
            Issue.record("expected a swipe"); return
        }
        #expect(abs(toY - 0.05) < 1e-9)
        #expect(DeviceGesture.wheel(dx: 0, dy: 5) == nil)
    }

    @Test func theListGroupsAndWordsItsRows() throws {
        let list = try #require(DeviceList(json: ["available": true, "reason": "", "devices": [
            ["id": "ios:a", "platform": "ios", "kind": "simulator", "state": "shutdown", "available": false, "canBoot": true,
             "name": "iPhone 16", "runtime": "iOS 27.0"],
            ["id": "ios:b", "platform": "ios", "kind": "simulator", "state": "ready", "available": true, "name": "iPhone 17 Pro",
             "runtime": "iOS 27.0", "checking": true],
            ["id": "android:c", "platform": "android", "kind": "physical", "state": "unauthorized", "available": false,
             "canBoot": false, "name": "Pixel", "runtime": "", "note": "Unlock the phone."],
        ] as [Any]]))
        #expect(list.groups.map { [$0.title] + $0.rows.map(\.id) } == [["Running", "ios:b"], ["Off", "ios:a"], ["Not available", "android:c"]])
        #expect(list.devices[1].subLine == "Simulator · iOS 27.0 · checking…")
        #expect(list.devices[0].subLine == "Simulator · iOS 27.0")
        #expect(list.devices[2].subLine == "Android phone · Unlock the phone.")
        #expect(list.isChanging)
    }

    @Test func readsTheEnginesAnswers() throws {
        let details = try #require(DeviceDetails(json: ["id": "ios:A", "name": "iPhone 17 Pro", "platform": "ios", "kind": "simulator",
                                                        "pointWidth": 402, "pointHeight": 874, "buttons": ["home", "lock"],
                                                        "keys": ["return"], "text": "unicode", "canRotate": true, "rawTouch": true]))
        #expect(details.pointWidth == 402 && details.rawTouch && details.buttons == ["home", "lock"])
        #expect(DeviceOutcome(json: ["ok": true, "id": "ios:B"], fallback: "x") == .ok(id: "ios:B"))
        #expect(DeviceOutcome(json: ["ok": false, "message": "No room."], fallback: "x") == .refused("No room."))
        #expect(DeviceOutcome(json: nil, fallback: "It would not start.") == .refused("It would not start."))
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let frozen = try #require(FrozenScreen(json: ["image": "data:image/png;base64,\(png.base64EncodedString())",
                                                      "width": 1206, "height": 2622, "tree": ["source": "core-simulator-ax", "root": settingsJSON] as [String: Any],
                                                      "treeError": "", "where": ["kind": "device", "place": "iOS Simulator", "name": "iPhone"]]))
        #expect(frozen.png == png && frozen.width == 1206 && frozen.tree?.nodeCount == 7)
        #expect(frozen.where_.place == "iOS Simulator")
        #expect(FrozenScreen(json: ["image": "not a data url"]) == nil)
    }
}

@Suite("Sending beyond this Mac, and the readout")
struct DeviceRoundThreeTests {
    @Test func sessionsOnPairedMachinesAreNamedByTheirMachine() {
        let machines: [String: Any] = [
            "machines": [["id": "m1", "name": "", "platform": "win32"], ["id": "m2", "name": "Studio", "platform": "darwin"]] as [Any],
            "links": [
                ["id": "m1", "hostPlatform": "", "sessions": [
                    ["id": "r1", "cwd": "C:\\work\\shop", "title": "shop", "exitCode": NSNull()],
                    ["id": "r2", "cwd": "C:\\work\\shop", "title": "Fixer", "exitCode": 1],
                ] as [Any]],
                ["id": "m2", "hostPlatform": "darwin", "sessions": [["id": "r3", "cwd": "/u/app", "title": "app", "exitCode": NSNull()]] as [Any]],
                ["id": "ghost", "sessions": [["id": "r4", "cwd": "/x"]] as [Any]],
            ] as [Any],
        ]
        let rows = AgentSessions.read([["id": "s1", "cwd": "/u/app", "title": "app", "exitCode": NSNull()]] as [Any], machines: machines)
        #expect(rows.map(\.label) == ["app · Session 1", "That PC · shop · Session 1", "That PC · Fixer", "Studio · app · Session 1"])
        #expect(rows.map(\.machineId) == ["", "m1", "m1", "m2"])
        #expect(rows[2].ended)
        #expect(AgentSessions.machineRefusal(["ok": true], machineName: "Studio") == nil)
        #expect(AgentSessions.machineRefusal(["ok": false, "message": "Folder not shared."], machineName: "Studio") == "Folder not shared.")
        #expect(AgentSessions.machineRefusal(nil, machineName: "Studio") == "Studio did not answer.")
    }

    @Test func theRailsNamesWinAndANumberIsNotAName() {
        let names = AgentSessions.railNames([(id: "s1", title: "Commander"), (id: "s2", title: "Session 2"), (id: "s3", title: " ")])
        #expect(names == ["s1": "Commander"])
        let rows = AgentSessions.read([["id": "s1", "cwd": "/u/app", "title": "app", "exitCode": NSNull()],
                                       ["id": "s2", "cwd": "/u/app", "title": "app", "exitCode": NSNull()]] as [Any], names: names)
        #expect(rows.map(\.label) == ["Commander", "app · Session 2"])
    }

    @Test func theReadoutReadsTheSameAsThePage() {
        func stats(_ painted: Int, _ received: Int) -> PlayerStats {
            var s = PlayerStats()
            s.received = received; s.decoded = received; s.painted = painted; s.dropped = 1
            s.decodeMs = [2, 3, 9]; s.inputToPictureMs = [120, 80, 95]
            s.stream = CGSize(width: 1206, height: 2622); s.canvas = CGSize(width: 355, height: 772)
            s.hardware = "yes"; s.codec = "avc1.640033"
            return s
        }
        #expect(DeviceDiagnostics.lines(before: stats(10, 12), now: stats(40, 42), seconds: 1, scale: 1, paused: false) == [
            "shown 30.0 fps · arriving 30.0 fps",
            "decode 3 ms (p95 9 ms) · hardware yes",
            "touch → picture 95 ms (last 95 ms)",
            "dropped 1 · restarts 0",
            "stream 1206×2622 → canvas 355×772 @1x · avc1.640033",
        ])
        #expect(DeviceDiagnostics.lines(before: nil, now: stats(0, 0), seconds: 0, scale: 2, paused: true)[0] == "paused — window hidden")
        #expect(DeviceDiagnostics.lines(before: nil, now: stats(0, 0), seconds: 0, scale: 2, paused: false)[0] == "shown – fps · arriving – fps")
        var list: [Double] = []
        for i in 0..<70 { PlayerStats.remember(&list, Double(i) + 0.04) }
        #expect(list.count == 60 && list.first == 10.0)
    }
}

@Suite("Sending to a server's terminal")
struct DeviceServerSendTests {
    @Test func serverTerminalsComeLastAndAreAddressedByTheirTab() {
        let rows = AgentSessions.read([["id": "s1", "cwd": "/u/app", "title": "app", "exitCode": NSNull()]] as [Any],
                                      servers: [(name: "prod", shells: [(tabId: "server srv1 k1", title: "Shell 1"), (tabId: "bogus", title: "x")])])
        #expect(rows.map(\.label) == ["app · Session 1", "prod · Shell 1"])
        #expect(rows.map(\.tabId) == ["s1", "server srv1 k1"])
        #expect(rows[1].onServer && rows[1].machineName == "prod")
        let machine = AgentSessionRow(id: "r1", cwd: "", provider: "", ended: false, label: "x", machineId: "m1", machineName: "PC")
        #expect(machine.tabId == "machine m1 r1")
    }
}
