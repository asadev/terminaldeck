/**
 * The `localhost` half of the wire, on this end.
 *
 * Two things here are worth a test that the rest of the codec did not need.
 *
 * **Base64 must be strict.** Every byte of a tunnelled HTTP response goes
 * through it, and a decoder that skips what it does not recognise turns a
 * corrupted frame into a *shorter* response body — which arrives at the browser
 * as a truncated page and gets blamed on the dev server, several layers away
 * from the thing that was actually wrong.
 *
 * **A port has to be a port.** It is the one number on this wire that decides
 * what a socket connects to, so `0`, `70000`, `"3000"` and `3000.5` are refused
 * here rather than carried to the Mac to be refused there.
 */

import XCTest
@testable import TerminalDeck

final class LocalhostWireTests: XCTestCase {

    // MARK: - The port list

    func testPortsAreDecodedAndOneBadRowDoesNotDiscardTheList() {
        let raw = #"""
        {"t":"ports","ports":[
          {"port":3000,"process":"node","guessed":false},
          {"port":0,"process":"broken","guessed":false},
          {"port":5173,"process":"unknown","guessed":true},
          {"port":8080},
          "not a row"
        ]}
        """#
        guard case let .ok(message, _) = WireCodec.decode(raw), case let .ports(list) = message else {
            return XCTFail("a ports frame should decode")
        }
        // A phone showing two of three ports is useful; one showing none because
        // the desktop sent a malformed row is not.
        XCTAssertEqual(list, [
            LocalPort(port: 3000, process: "node", guessed: false),
            LocalPort(port: 5173, process: "unknown", guessed: true),
        ])
    }

    func testPortsWithNoListIsRefusedRatherThanReadAsEmpty() {
        // Empty and malformed are different claims: one says "nothing is
        // running", the other says "that was not the desktop".
        guard case .failed = WireCodec.decode(#"{"t":"ports"}"#) else {
            return XCTFail("a ports frame with no list should be refused")
        }
    }

    // MARK: - Tunnels

    func testTunnelFramesCarryTheirIdAndReason() {
        guard case let .ok(opened, _) = WireCodec.decode(#"{"t":"tunnel.opened","id":"t1","port":3000}"#),
              case let .tunnelOpened(id, port) = opened else {
            return XCTFail("tunnel.opened should decode")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(port, 3000)

        guard case let .ok(closed, _) = WireCodec.decode(#"{"t":"tunnel.closed","id":"t1","message":"Stopped from the Mac."}"#),
              case let .tunnelClosed(_, detail) = closed else {
            return XCTFail("tunnel.closed should decode")
        }
        XCTAssertEqual(detail, "Stopped from the Mac.")
    }

    func testATunnelThatClosedWithoutAReasonStillCloses() {
        // The closing is the message. A missing sentence is a worse screen, not
        // a reason to keep showing a page that has nothing behind it.
        guard case let .ok(message, _) = WireCodec.decode(#"{"t":"tunnel.closed","id":"t1"}"#),
              case let .tunnelClosed(_, detail) = message else {
            return XCTFail("tunnel.closed without a message should still decode")
        }
        XCTAssertFalse(detail.isEmpty)
    }

    func testTunnelOpenedWithoutAUsablePortIsRefused() {
        for port in ["0", "70000", "\"3000\"", "3000.5", "true", "null"] {
            guard case .failed = WireCodec.decode(#"{"t":"tunnel.opened","id":"t1","port":\#(port)}"#) else {
                return XCTFail("port \(port) should be refused")
            }
        }
    }

    // MARK: - Bytes

    func testNetDataRoundTripsThroughBase64() {
        // Deliberately not text: the tunnel carries whatever a socket carries,
        // and a codec that only survives ASCII would corrupt every image.
        let bytes = Data((0 ... 255).map { UInt8($0) })
        let encoded = WireCodec.encode(.netData(ch: "c1", data: bytes))
        guard case let .ok(message, _) = WireCodec.decode(encoded), case let .netData(ch, out) = message else {
            return XCTFail("net.data should round-trip")
        }
        XCTAssertEqual(ch, "c1")
        XCTAssertEqual(out, bytes)
    }

    func testNetDataThatIsNotBase64IsRefusedRatherThanPartlyDecoded() {
        // The failure this prevents: a decoder that returns what it managed to
        // read hands a short buffer to a socket, and the browser sees a
        // truncated response from a dev server that sent a whole one.
        for payload in ["not base64!", "AA=A", "QUJD\n", "☃☃☃☃"] {
            guard case .failed = WireCodec.decode(#"{"t":"net.data","ch":"c1","data":"\#(payload)"}"#) else {
                return XCTFail("\(payload) should not decode as base64")
            }
        }
    }

    func testAnEmptyPayloadIsLegal() {
        // A zero-length write is not an error, and refusing one would close a
        // stream over nothing.
        guard case let .ok(message, _) = WireCodec.decode(#"{"t":"net.data","ch":"c1","data":""}"#),
              case let .netData(_, data) = message else {
            return XCTFail("an empty net.data should decode")
        }
        XCTAssertEqual(data.count, 0)
    }

    func testAcknowledgementsBeyondAWindowAreRefused() {
        // An ack larger than anything that can be in flight is either a bug on
        // the far end or an attempt to unblock a paused reader by claiming
        // progress that never happened.
        for bytes in [0, -1, Wire.netWindowBytes + 1] {
            guard case .failed = WireCodec.decode(#"{"t":"net.ack","ch":"c1","bytes":\#(bytes)}"#) else {
                return XCTFail("an ack of \(bytes) should be refused")
            }
        }
        guard case let .ok(message, _) = WireCodec.decode(#"{"t":"net.ack","ch":"c1","bytes":1448}"#),
              case let .netAck(_, bytes) = message else {
            return XCTFail("a plausible ack should decode")
        }
        XCTAssertEqual(bytes, 1448)
    }

    // MARK: - Outbound

    func testEveryLocalhostVerbEncodesToTheShapeTheDesktopParses() {
        let cases: [(ClientMessage, [String: Any])] = [
            (.ports, ["t": "ports"]),
            (.tunnelOpen(id: "t1", port: 3000), ["t": "tunnel.open", "id": "t1", "port": 3000]),
            (.tunnelClose(id: "t1"), ["t": "tunnel.close", "id": "t1"]),
            (.netOpen(ch: "c1", tunnel: "t1"), ["t": "net.open", "ch": "c1", "tunnel": "t1"]),
            (.netData(ch: "c1", data: Data("hi".utf8)), ["t": "net.data", "ch": "c1", "data": "aGk="]),
            (.netAck(ch: "c1", bytes: 64), ["t": "net.ack", "ch": "c1", "bytes": 64]),
            (.netClose(ch: "c1"), ["t": "net.close", "ch": "c1"]),
        ]
        for (message, expected) in cases {
            let object = decodeOutbound(WireCodec.encode(message))
            XCTAssertEqual(object.keys.sorted(), expected.keys.sorted(), "\(expected["t"] ?? "?")")
            for (key, value) in expected {
                XCTAssertEqual(String(describing: object[key] ?? "nil"), String(describing: value), key)
            }
        }
    }

    /// The capability gate. A desktop that has never heard of this feature does
    /// not send the field, and nothing may be offered on that connection.
    func testLocalhostIsOnlyOfferedWhenTheDesktopAdvertisesIt() {
        let without = #"{"t":"welcome","protocol":1,"deviceId":"d","deviceName":"p","token":null,"sessions":[]}"#
        guard case let .ok(plain, _) = WireCodec.decode(without),
              case let .welcome(_, _, _, _, _, none) = plain else {
            return XCTFail("a v1 welcome should still decode")
        }
        XCTAssertFalse(none.contains(WireCapability.localhost))

        let with = #"{"t":"welcome","protocol":1,"deviceId":"d","deviceName":"p","token":null,"sessions":[],"capabilities":["localhost"]}"#
        guard case let .ok(newer, _) = WireCodec.decode(with),
              case let .welcome(_, _, _, _, _, offered) = newer else {
            return XCTFail("a welcome with capabilities should decode")
        }
        XCTAssertTrue(offered.contains(WireCapability.localhost))
    }

    private func decodeOutbound(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("encode produced something that is not a JSON object")
            return [:]
        }
        return object
    }
}
