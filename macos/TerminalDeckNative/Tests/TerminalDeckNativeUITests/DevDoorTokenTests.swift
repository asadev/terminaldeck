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
}
