import XCTest
@testable import TerminalDeckNativeCore

/// Read-only wire fixtures. No installed data, process reads, engine or AI calls.
final class ATWORKCoreTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TD_ATWORK_FOCUSED"] == "1" else { throw XCTSkip("WIP ATWORK") }
    }
    private func wire(_ json: String) throws -> NativeRPCValue { try .parseJSON(Data(json.utf8)) }

    func testLegacyAgentShowsUnavailableResourcesInsteadOfZero() throws {
        let row = try XCTUnwrap(AWWatchAgent.decode(wire(#"{"id":"old","sourceID":"old","state":"working"}"#)))
        let value = row.wireValue
        for key in ["pid", "cpuPercent", "memoryBytes", "threads", "tokensToday"] {
            XCTAssertNil(value[key].number, "Legacy \(key) must stay unavailable")
        }
    }

    func testMeasuredResourcesRoundTripWithoutLosingPrecision() throws {
        let input = try wire(#"{"id":"one","sourceID":"one","state":"working","pid":42001,"cpuPercent":143.75,"memoryBytes":3221225472,"threads":12,"tokensToday":125003,"sourceApp":"Terminal Deck"}"#)
        let row = try XCTUnwrap(AWWatchAgent.decode(input))
        let value = row.wireValue
        for key in ["pid", "cpuPercent", "memoryBytes", "threads", "tokensToday"] {
            XCTAssertEqual(value[key].number, input[key].number, "Resource field \(key) changed")
        }
        XCTAssertEqual(value["sourceApp"].string, "Terminal Deck")
        XCTAssertEqual(try XCTUnwrap(AWWatchAgent.decode(value)), row)
    }

    func testDeniedResourceReadKeepsAgentAndItsRealState() throws {
        let row = try XCTUnwrap(AWWatchAgent.decode(wire(#"{"id":"external","sourceID":"external","kind":"device","state":"waiting","pid":42002,"cpuPercent":null,"memoryBytes":null,"sourceApp":"Cursor"}"#)))
        XCTAssertEqual(row.state, .waiting)
        XCTAssertEqual(row.kind, "device")
        XCTAssertNil(row.wireValue["cpuPercent"].number)
        XCTAssertNil(row.wireValue["memoryBytes"].number)
        XCTAssertEqual(row.wireValue["sourceApp"].string, "Cursor")
    }

    func testUnavailableMetricsRemainUnavailableAfterInventoryFiltering() throws {
        let measured = try XCTUnwrap(AWWatchAgent.decode(wire(#"{"id":"measured","sourceID":"measured","state":"working","project":"/fixture/one","cpuPercent":12.5,"memoryBytes":1048576}"#)))
        let denied = try XCTUnwrap(AWWatchAgent.decode(wire(#"{"id":"denied","sourceID":"denied","state":"working","project":"/fixture/two","cpuPercent":null,"memoryBytes":null}"#)))
        let rows = AWWatchProjection.filtered([measured, denied], project: "/fixture/two")
        XCTAssertEqual(rows.map(\.id), ["denied"])
        XCTAssertNil(rows.first?.wireValue["cpuPercent"].number)
    }
}

extension ATWORKCoreTests {
    func testStableProjectScopeUsesProjectIdRatherThanFolderBasename() throws {
        let first = try XCTUnwrap(AWWatchAgent.decode(wire(#"{"id":"one","sourceID":"one","state":"working","project":"/fixture/a/shared","projectId":"imatch"}"#)))
        let second = try XCTUnwrap(AWWatchAgent.decode(wire(#"{"id":"two","sourceID":"two","state":"working","project":"/fixture/b/shared","projectId":"crm"}"#)))
        XCTAssertEqual(AWWatchProjection.filtered([first, second], project: "imatch").map(\.id), ["one"])
        XCTAssertEqual(AWWatchProjection.filtered([first, second], project: "crm").map(\.id), ["two"])
        XCTAssertEqual(first.wireValue["projectId"].string, "imatch")
    }

    func testRemotePidCannotBeReadAsLocalProcess() throws {
        let session = try wire(#"{"id":"one","provider":"claude","attention":"working","pid":42000,"tokensToday":100}"#)
        let local = try XCTUnwrap(AWWatchProjection.inventory(sessions: [session], tasks: []).first)
        let remote = try XCTUnwrap(AWWatchProjection.inventory(sessions: [session], tasks: [], machineID: "remote").first)
        XCTAssertEqual(local.pid, 42000)
        XCTAssertNil(remote.pid)
        XCTAssertEqual(remote.tokensToday, 100)
    }

    func testMalformedResourceValuesNeverTrapOrClaimMeasuredUsage() throws {
        let row = try XCTUnwrap(AWWatchAgent.decode(wire(#"{"id":"bad","sourceID":"bad","state":"working","pid":999999999999999,"cpuPercent":-1,"memoryBytes":-1,"threads":1.5,"tokensToday":-1}"#)))
        XCTAssertNil(row.pid)
        XCTAssertNil(row.cpuPercent)
        XCTAssertNil(row.memoryBytes)
        XCTAssertNil(row.threads)
        XCTAssertNil(row.tokensToday)
    }
}
