import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppDeviceTestPortFramesRound: XCTestCase {
    func testRoundRebuiltClampedCutRenumberedAndDropsUnexpectedFields() throws {
        let raw = try NativeRPCValue.fromFoundation(["id": "r1", "createdAt": 5, "where": ["kind": "device", "place": "iOS Simulator", "name": String(repeating: "x", count: 500), "deviceId": "ios:1", "evil": "dropped"], "frame": ["width": 1206.4, "height": -3], "note": "Make #1 bold.", "annotations": [["id": "a", "n": 9, "rect": ["x": -1, "y": 2, "width": 0.5, "height": 0.5], "note": "one", "element": ["role": "button", "script": "x"]], ["id": "b", "rect": [:], "element": "not an object"]]])
        let round = BackendAppDeviceParsing.round(raw)
        XCTAssertEqual(round["where"], BackendAppSessionTestPortObject([("kind", .string("device")), ("place", .string("iOS Simulator")), ("name", .string(String(repeating: "x", count: 200))), ("deviceId", .string("ios:1"))]))
        XCTAssertEqual(round["frame"], BackendAppSessionTestPortObject([("width", .number(1206)), ("height", .number(0))]))
        let entries = try XCTUnwrap(round["annotations"].elements); XCTAssertEqual(entries.map { $0["n"].number }, [1, 2])
        XCTAssertEqual(entries[0]["rect"], BackendAppSessionTestPortObject([("x", .number(0)), ("y", .number(1)), ("width", .number(0.5)), ("height", .number(0.5))]))
        XCTAssertEqual(entries[0]["element"], BackendAppSessionTestPortObject([("role", .string("button"))])); XCTAssertEqual(round["note"].string, "Make #1 bold."); XCTAssertFalse(entries[0].has("note")); XCTAssertEqual(entries[1]["element"], .null)
    }
    func testRoundMissingIDIsMadeUpWithoutFailing() { let value = BackendAppDeviceParsing.round(.null, now: 5); XCTAssertTrue(value["id"].string?.hasPrefix("round-") == true); XCTAssertEqual(value["note"].string, "") }
    func testNodeCopiesOnlyAppFieldsAndNormalizedFrame() throws {
        let raw = try NativeRPCValue.fromFoundation(["ref": "ax:1", "role": "AXButton", "label": "Pay", "actions": ["AXPress"], "visibleFraction": 1, "frame": ["normalized": ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4], "points": ["x": 1, "y": 2, "width": 3, "height": 4]]])
        let expected = try NativeRPCValue.parseJSON(Data(#"{"ref":"ax:1","role":"AXButton","label":"Pay","frame":{"normalized":{"x":0.1,"y":0.2,"width":0.3,"height":0.4}}}"#.utf8))
        XCTAssertEqual(BackendAppDeviceParsing.readNode(raw), expected)
    }
    func testNodeNeverCarriesRedactedValue() throws { let raw = try NativeRPCValue.parseJSON(Data(#"{"ref":"p","role":"AXSecureTextField","value":"••••","valueRedacted":true}"#.utf8)); let node = try XCTUnwrap(BackendAppDeviceParsing.readNode(raw)); XCTAssertFalse(node.has("value")); XCTAssertEqual(node["ref"].string, "p"); XCTAssertEqual(node["role"].string, "AXSecureTextField"); XCTAssertEqual(node["valueRedacted"].bool, true) }
    func testReactNativeSourceLocationSurvives() throws { let raw = try NativeRPCValue.parseJSON(Data(#"{"ref":"rn:1","component":"PayButton","sourceLocation":{"file":"src/Pay.tsx","line":12}}"#.utf8)); XCTAssertEqual(BackendAppDeviceParsing.readNode(raw)?["sourceLocation"], BackendAppSessionTestPortObject([("file", .string("src/Pay.tsx")), ("line", .number(12))])) }
}
