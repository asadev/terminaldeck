import XCTest
@testable import TerminalDeckBackend

/// Numeric literal parsing only: these tests never call resolve(_:), DNS,
/// sockets or any network service. Address strings are handled solely by the
/// system's numeric conversion APIs; none is used as a connection target.
final class BackendAppsMCPDNSTests: XCTestCase {
    func testIPv4CanonicalLiteralsPreserveAllFourOctets() {
        for address in ["0.0.0.0", "127.0.0.1", "192.0.2.1", "198.51.100.42", "203.0.113.255", "255.255.255.255"] {
            XCTAssertEqual(BackendAppsMCPDNS.numericAddress(address), address)
        }
    }

    func testIPv6CanonicalizationRemovesLeadingZerosAndUppercase() {
        let cases = [
            ("0:0:0:0:0:0:0:0", "::"),
            ("0000:0000:0000:0000:0000:0000:0000:0001", "::1"),
            ("2001:0DB8:0000:0000:0000:0000:0000:0001", "2001:db8::1"),
            ("2001:0DB8:0001:0002:0003:0004:0005:0006", "2001:db8:1:2:3:4:5:6"),
            ("2001:DB8:0:0:1:0:0:1", "2001:db8::1:0:0:1")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(BackendAppsMCPDNS.numericAddress(input), expected, input)
        }
    }

    func testBalancedBracketedIPv6LiteralsNormalizeWithoutBrackets() {
        let cases = [
            ("[::]", "::"),
            ("[::1]", "::1"),
            ("[2001:0DB8:0000:0000:0000:0000:0000:0001]", "2001:db8::1")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(BackendAppsMCPDNS.numericAddress(input), expected, input)
        }
    }

    func testIPv4MappedIPv6StaysAnIPv6Literal() {
        for input in ["::ffff:192.0.2.128", "0:0:0:0:0:FFFF:C000:0280", "[::FFFF:192.0.2.128]"] {
            XCTAssertEqual(BackendAppsMCPDNS.numericAddress(input), "::ffff:192.0.2.128", input)
        }
        XCTAssertNotEqual(BackendAppsMCPDNS.numericAddress("::ffff:192.0.2.128"), "192.0.2.128")
    }

    func testMalformedNumericAddressesAndBracketDamageAreRejected() {
        let inputs = [
            "", "[]", "[", "]", "[::1", "::1]", "[[::1]]", "[::1]]", "[[::1]",
            "[192.0.2.1]", "[192.0.2.1", "192.0.2.1]", "[[192.0.2.1]]", "2001:[db8]::1",
            "192.0.2", "192.0.2.256", "192.0.-1.1", "192.0.2.1.5", "192..2.1", "192.0.2.1.",
            "192.000.002.001", "127.1", "2130706433", "0x7f000001", "2001:db8::g", "2001::db8::1",
            "2001:db8:1:2:3:4:5", "2001:db8:1:2:3:4:5:6:7", "::ffff:192.0.2.256", "fe80::1%en0"
        ]
        for input in inputs { XCTAssertNil(BackendAppsMCPDNS.numericAddress(input), input.debugDescription) }
    }

    func testHostnamesURLsPortsPathsCIDRAndShellTextAreRejected() {
        let inputs = [
            "localhost", "example.invalid", "192.0.2.1.example.invalid", "192.0.2.1:22", "[::1]:22",
            "ssh://192.0.2.1", "http://[::1]", "https://192.0.2.1/path", "user@192.0.2.1",
            "192.0.2.1/24", "2001:db8::/64", "/tmp/192.0.2.1", "192.0.2.1/../../file", "::1/file",
            "192.0.2.1; echo fixture", "192.0.2.1 && echo fixture", "192.0.2.1|cat", "`echo 192.0.2.1`",
            "$(echo 192.0.2.1)", "$ADDR", "'192.0.2.1'", "\"192.0.2.1\"", "192.0.2.1#comment"
        ]
        for input in inputs { XCTAssertNil(BackendAppsMCPDNS.numericAddress(input), input.debugDescription) }
    }

    func testControlsWhitespaceAndUnicodeDamageNeverAllowACStringPrefix() {
        for scalarValue in Array(0...31) + [127] {
            let control = String(UnicodeScalar(scalarValue)!)
            for address in ["192.0.2.1", "2001:db8::1"] {
                for input in [control + address, address + control, address + control + ";ignored", "[" + address + "]" + control] {
                    XCTAssertNil(BackendAppsMCPDNS.numericAddress(input), input.debugDescription)
                }
            }
        }
        for damage in [" ", "\u{00a0}", "\u{200b}", "\u{2028}", "\u{2029}", "\u{feff}"] {
            for input in [damage + "192.0.2.1", "192.0.2.1" + damage, "2001:db8:" + damage + ":1"] {
                XCTAssertNil(BackendAppsMCPDNS.numericAddress(input), input.debugDescription)
            }
        }
        for input in ["１９２.０.２.１", "١٩٢.٠.٢.١", "2001:db8::💥"] {
            XCTAssertNil(BackendAppsMCPDNS.numericAddress(input), input.debugDescription)
        }
    }
}
