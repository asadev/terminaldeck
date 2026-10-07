import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppDeviceTestPortFramesRound: XCTestCase {
    func testFrameRoundTripExactKindLengthAndPayload() throws {
        let wire = try BackendAppDeviceFrames.encode(kind: 2, payload: Data(#"{"id":"1"}"#.utf8)); XCTAssertEqual(wire.first, 2)
        XCTAssertEqual(Array(wire[1..<5]), [0, 0, 0, 10])
        var reader = BackendAppDeviceFrameReader(); let frames = try reader.push(wire)
        XCTAssertEqual(frames.count, 1); XCTAssertEqual(frames[0].kind, 2); XCTAssertEqual(String(decoding: frames[0].payload, as: UTF8.self), #"{"id":"1"}"#)
    }
    func testFrameWaitsAcrossEveryByteBoundary() throws {
        let wire = try BackendAppDeviceFrames.encode(kind: 0x12, payload: Data(repeating: 7, count: 300)); var reader = BackendAppDeviceFrameReader(), seen: [BackendAppDeviceFrame] = []
        for byte in wire { seen += try reader.push(Data([byte])) }; XCTAssertEqual(seen.count, 1); XCTAssertEqual(seen[0].payload.count, 300)
    }
    func testEveryCoalescedFrameHasExactPayload() throws {
        var wire = try BackendAppDeviceFrames.encode(kind: 2, payload: Data("a".utf8)); wire.append(try BackendAppDeviceFrames.encode(kind: 0x12, payload: Data("bb".utf8))); wire.append(try BackendAppDeviceFrames.encode(kind: 0x20, payload: Data("ccc".utf8)))
        var reader = BackendAppDeviceFrameReader(); let frames = try reader.push(wire)
        XCTAssertEqual(frames.map(\.kind), [2, 0x12, 0x20]); XCTAssertEqual(frames.map { String(decoding: $0.payload, as: UTF8.self) }, ["a", "bb", "ccc"])
    }
    func testReaderDoesNotPinOrOverwriteOldPayload() throws {
        var reader = BackendAppDeviceFrameReader(); let first = try reader.push(BackendAppDeviceFrames.encode(kind: 0x12, payload: Data("first".utf8)))[0]
        _ = try reader.push(BackendAppDeviceFrames.encode(kind: 0x12, payload: Data("second".utf8))); XCTAssertEqual(String(decoding: first.payload, as: UTF8.self), "first")
    }
    func testForbiddenLengthFailsWithoutAllocatingPayload() { var reader = BackendAppDeviceFrameReader(); XCTAssertThrowsError(try reader.push(Data([0x12, 4, 0, 0, 1]))) { XCTAssertTrue($0.localizedDescription.contains("never should")) } }
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
