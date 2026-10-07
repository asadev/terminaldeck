import XCTest
@testable import TerminalDeckBackend

// src/shared/short-code.test.ts, minting half (the reading half lives in BackendFoundationTestsBHostVersionCode).
// Compiled only once production gains the seam requested in NIGHT-REQUESTS.md (lane S6, C6):
//   enum BackendShortCode { static let alphabet, length, space, wordBytes, draws, entropyBytes, drawLimit;
//                           static func codeFromBytes(_ bytes: [UInt8]) throws -> String   // throws BackendShortCodeError
//                           static func format(_ digits: String) -> String }
//   enum BackendShortCodeError: Error { case tooLittleRandomness, rejectionRegion }
// Build with -Xswiftc -DS6_SHORTCODE_SEAM after the seam lands (or drop the #if).
final class BackendFoundationTestsS6C6ShortCode: XCTestCase {
    private func word(_ draw: UInt64) -> [UInt8] { [UInt8((draw >> 24) & 0xff), UInt8((draw >> 16) & 0xff), UInt8((draw >> 8) & 0xff), UInt8(draw & 0xff)] }
    private func words(_ draws: UInt64...) -> [UInt8] { draws.flatMap(word) }
    private var limit: UInt64 { UInt64(BackendShortCode.drawLimit) }

    func testFormatIsSixDigitsAndNoGrouping() throws {
        var rng = SystemRandomNumberGenerator()
        XCTAssertEqual(BackendShortCode.format("123456"), "123456")
        for _ in 0..<200 {
            let code = try BackendShortCode.codeFromBytes((0..<BackendShortCode.entropyBytes).map { _ in UInt8.random(in: 0...255, using: &rng) })
            XCTAssertNotNil(code.range(of: "^[0-9]{6}$", options: .regularExpression)); XCTAssertEqual(code.count, BackendShortCode.length)
        }
        XCTAssertEqual(BackendShortCode.alphabet, "0123456789"); XCTAssertEqual(BackendShortCode.space, 1_000_000)
    }
    func testAcceptsWholeCyclesAndRejectsTheSkewedTail() throws {
        XCTAssertEqual(limit % UInt64(BackendShortCode.space), 0)
        XCTAssertLessThanOrEqual(limit, 1 << 32)
        XCTAssertLessThan((1 << 32) - limit, UInt64(BackendShortCode.space))
        XCTAssertEqual(limit, 4_294_000_000); XCTAssertEqual(limit / UInt64(BackendShortCode.space), 4294)
        XCTAssertEqual(try BackendShortCode.codeFromBytes(words(limit + 7, 123_456, 0, 0)), "123456")
        XCTAssertEqual(try BackendShortCode.codeFromBytes(words(limit - 1, 0, 0, 0)), "999999")
        XCTAssertEqual(try BackendShortCode.codeFromBytes(words(limit, 424_242, 0, 0)), "424242")
    }
    func testSmallDrawsArePaddedToSixDigits() throws {
        XCTAssertEqual(try BackendShortCode.codeFromBytes(words(0, 0, 0, 0)), "000000")
        XCTAssertEqual(try BackendShortCode.codeFromBytes(words(7, 0, 0, 0)), "000007")
        XCTAssertEqual(try BackendShortCode.codeFromBytes(words(UInt64(BackendShortCode.space) - 1, 0, 0, 0)), "999999")
    }
    func testUniformAcrossBucketsFromDeterministicXorshift() throws {
        var state: UInt32 = 0x1337_beef
        func next() -> UInt32 { state ^= state << 13; state ^= state >> 17; state ^= state << 5; return state }
        var buckets = [Int](repeating: 0, count: 100)
        for _ in 0..<400_000 {
            var supply: [UInt8] = []
            for _ in 0..<BackendShortCode.draws { supply += word(UInt64(next())) }
            buckets[Int(try BackendShortCode.codeFromBytes(supply))! / 10_000] += 1
        }
        XCTAssertGreaterThan(buckets.min()!, 3700); XCTAssertLessThan(buckets.max()!, 4300); XCTAssertEqual(buckets.reduce(0, +), 400_000)
    }
    func testRefusesShortRandomnessAndAllRejectedDraws() {
        XCTAssertThrowsError(try BackendShortCode.codeFromBytes([UInt8](repeating: 0, count: BackendShortCode.entropyBytes - 1))) { XCTAssertEqual($0 as? BackendShortCodeError, .tooLittleRandomness) }
        let doomed = (0..<BackendShortCode.draws).flatMap { _ in word(limit) }
        XCTAssertThrowsError(try BackendShortCode.codeFromBytes(doomed)) { XCTAssertEqual($0 as? BackendShortCodeError, .rejectionRegion) }
        XCTAssertGreaterThanOrEqual(BackendShortCode.draws, 4); XCTAssertEqual(BackendShortCode.entropyBytes, BackendShortCode.wordBytes * BackendShortCode.draws)
    }
    func testFormatRoundTripsThroughNormalise() {
        for digits in ["000000", "123456", "999999", "000007"] { XCTAssertEqual(PairingCodeParser.normalise(BackendShortCode.format(digits)), BackendShortCode.format(digits)) }
    }
}
