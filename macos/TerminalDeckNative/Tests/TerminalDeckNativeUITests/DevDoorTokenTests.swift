import Foundation
import XCTest
@testable import TerminalDeckNative

/// #612: the dev copy's doors (DevReload.swift) answer only this launch's secret and write only inside the dev folder.
final class DevDoorTokenTests: XCTestCase {
    func testANotificationWithoutTheTokenIsIgnored() {
        let token = "dev-door-" + UUID().uuidString
        XCTAssertNil(DevReload.request(#"{"channel":"settings:get","args":[],"out":"/tmp/x.json"}"#, token: token))
        XCTAssertNil(DevReload.request(#"{"token":"wrong","channel":"settings:get"}"#, token: token))
        XCTAssertNil(DevReload.request("open|Title|Text", token: token), "The old bare objects are ignored too.")
        XCTAssertNil(DevReload.request(#"{"token":""}"#, token: ""), "No secret at launch: every door stays shut.")
        XCTAssertEqual(DevReload.request(#"{"token":"\#(token)","channel":"settings:get"}"#, token: token)?["channel"] as? String, "settings:get")
    }
    func testAnswersAreWrittenOnlyInsideTheDevFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dev-door-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNotNil(DevReload.output(folder.appendingPathComponent("answer.json").path, folder: folder))
        XCTAssertNil(DevReload.output("/tmp/x.json", folder: folder))
        XCTAssertNil(DevReload.output(folder.path + "/../escape.json", folder: folder))
        XCTAssertNil(DevReload.output("answer.json", folder: folder), "A relative path is refused.")
        XCTAssertNil(DevReload.output(folder.appendingPathComponent("answer.json").path, folder: nil), "No dev folder: nothing is written.")
    }
    /// 17 Nov: the mention door was open to any app on the Mac in a debug-packaged public build. It now has the same lock.
    func testTheMentionDoorAnswersOnlyTheTokenAndWritesOnlyInsideTheDevFolder() throws {
        let token = "dev-door-" + UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dev-door-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inside = folder.appendingPathComponent("mention.json").path
        XCTAssertNil(HootMentionDevDoor.ask(#"{"text":"@decker hi","mentions":[],"out":"\#(inside)"}"#, token: token, folder: folder), "No token: ignored.")
        XCTAssertNil(HootMentionDevDoor.ask(#"{"token":"wrong","text":"hi","out":"\#(inside)"}"#, token: token, folder: folder), "Wrong token: ignored.")
        XCTAssertNil(HootMentionDevDoor.ask(#"{"token":"","text":"hi","out":"\#(inside)"}"#, token: "", folder: folder), "No secret at launch: shut.")
        XCTAssertNil(HootMentionDevDoor.ask(#"{"token":"\#(token)","text":"hi","out":"/tmp/x.json"}"#, token: token, folder: folder), "Outside dev-out: refused.")
        XCTAssertNil(HootMentionDevDoor.ask(#"{"token":"\#(token)","text":"hi","out":"\#(inside)"}"#, token: token, folder: nil), "No dev folder: refused.")
        let door = try XCTUnwrap(HootMentionDevDoor.ask(#"{"token":"\#(token)","text":"hi","out":"\#(inside)"}"#, token: token, folder: folder))
        XCTAssertEqual(door.wire["text"].string, "hi")
        XCTAssertEqual(door.out.lastPathComponent, "mention.json")
        XCTAssertNil(HootMentionDevDoor.ask(nil, token: token, folder: folder))
    }
}
