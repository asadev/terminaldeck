/**
 * The arguments of a confirmation, and the reader that keeps them honest.
 *
 * Everything here is in service of one sentence from `COPILOT-REMOTE.md` §4.3:
 * *a consent prompt without enough context becomes a reflex Yes, and a gate that
 * is always answered yes is worse than no gate, because it looks like
 * protection.* The arguments are what turn that prompt from a shape into a
 * decision, so the ways they can be quietly wrong are worth a file of their own.
 *
 * Three of them, and each has been a real bug in some client somewhere:
 *
 * **Order.** `JSONSerialization` returns an `NSDictionary`, whose key order is
 * hash order and is not stable between runs of the same build. The desktop
 * composes `args` in the tool's own declaration order — the order its own dialog
 * shows — so a phone that used the dictionary's order would render the same
 * question in a different shape from the Mac, and two renderings of one consent
 * prompt is how somebody approves one thing having read another.
 *
 * **Spelling.** `String(describing:)` on the objects Foundation produces prints
 * Objective-C debug output: `1` for a JSON `true`, `<null>` for a null, and
 * `{ key = value; }` for a nested argument. On a screen whose whole job is
 * *verbatim*, a boolean drawn as `1` is a misquote.
 *
 * **Refusing rather than half-reading.** A frame that will not parse produces
 * nil and the caller falls back to a sorted list that says it is sorted, rather
 * than a partial argument list that looks complete.
 */

import XCTest
@testable import TerminalDeck

final class CopilotArgumentsTests: XCTestCase {

    // MARK: - Order and spelling

    /// The order is the document's, not the dictionary's — and it is checked
    /// against a key set Foundation is very likely to reorder.
    func testArgumentsKeepTheOrderTheToolWroteThem() {
        let frame = #"""
        {"t":"copilot.ask","question":{"id":"q1","tool":"sessions.send","summary":"Type into “api”",
         "args":{"zeta":1,"alpha":"two","middle":true,"beta":null}}}
        """#
        guard let arguments = CopilotArguments.fromAsk(rawFrame: frame) else {
            return XCTFail("the frame should read")
        }
        XCTAssertEqual(arguments.map(\.name), ["zeta", "alpha", "middle", "beta"])
        XCTAssertEqual(arguments.map(\.value), ["1", "two", "true", "null"])
    }

    /**
     * A string is drawn as its own text; everything else as its JSON spelling.
     *
     * The one place this is not literally verbatim, and the place where being
     * literal would be less honest: quoting `"light"` on screen would be showing
     * somebody JSON rather than showing them what is about to happen. A number,
     * a boolean, a null, an object and an array all keep their JSON, because for
     * those the JSON *is* how a person reads them.
     */
    func testValuesAreDrawnAsAPersonWouldReadThem() {
        let frame = #"""
        {"t":"copilot.ask","question":{"args":{
          "text":"echo hi","count":42,"exact":0.5,"flag":false,"nothing":null,
          "nested":{"b":1,"a":2},"list":["x","y"]}}}
        """#
        guard let arguments = CopilotArguments.fromAsk(rawFrame: frame) else {
            return XCTFail("the frame should read")
        }
        let byName = Dictionary(uniqueKeysWithValues: arguments.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["text"], "echo hi", "a string is its own text, unquoted")
        XCTAssertEqual(byName["count"], "42")
        XCTAssertEqual(byName["exact"], "0.5", "the literal the tool wrote, not a re-formatted double")
        XCTAssertEqual(byName["flag"], "false", "a JSON false is `false`, never `0`")
        XCTAssertEqual(byName["nothing"], "null")
        XCTAssertEqual(byName["nested"], #"{"b":1,"a":2}"#, "and the nested order survives too")
        XCTAssertEqual(byName["list"], #"["x","y"]"#)
    }

    /// Escapes come back as the characters they stand for, including the ones
    /// outside the basic plane. An argument containing an emoji arriving as two
    /// replacement characters is a misquote of exactly the kind this file is
    /// about.
    func testEscapesAndSurrogatePairsSurvive() {
        let frame = #"""
        {"t":"copilot.ask","question":{"args":{"path":"a\\b\"c\nd","emoji":"🚀"}}}
        """#
        guard let arguments = CopilotArguments.fromAsk(rawFrame: frame) else {
            return XCTFail("the frame should read")
        }
        let byName = Dictionary(uniqueKeysWithValues: arguments.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["path"], "a\\b\"c\nd")
        XCTAssertEqual(byName["emoji"], "🚀")
    }

    /// A frame with no `args`, or one that is not an ask at all, reads as nil so
    /// the caller can say which list it is showing.
    func testAFrameWithNoArgumentsObjectReadsAsNothing() {
        XCTAssertNil(CopilotArguments.fromAsk(rawFrame: #"{"t":"copilot.ask","question":{"id":"q"}}"#))
        XCTAssertNil(CopilotArguments.fromAsk(rawFrame: #"{"t":"pong"}"#))
        XCTAssertNil(CopilotArguments.fromAsk(rawFrame: "not json at all"))
    }

    /**
     * The fallback is sorted, and sorted deliberately.
     *
     * Hash order is not stable between runs, so leaving it alone would draw the
     * same question two different ways — and a consent screen that reshuffles
     * itself is one somebody stops reading. Sorting is a claim the sheet then
     * makes out loud, because *as the tool wrote them* and *by name* are two
     * different claims and only one is true at a time.
     */
    func testTheFallbackIsSortedAndStillSpellsValuesProperly() {
        let arguments = CopilotArguments.sorted(["zeta": 1, "alpha": true, "middle": NSNull()])
        XCTAssertEqual(arguments.map(\.name), ["alpha", "middle", "zeta"])
        XCTAssertEqual(arguments.map(\.value), ["true", "null", "1"],
                       "a bridged NSNumber holding a boolean is `true`, not `1`")
    }

    /// A value nobody could read on a phone is cut **and says so**. A shortened
    /// argument that does not announce itself is a consent prompt misquoting the
    /// request it is asking about.
    func testAnEnormousValueIsCutAndSaysSo() {
        let huge = String(repeating: "x", count: CopilotArguments.maxValueChars + 500)
        let arguments = CopilotArguments.sorted(["blob": huge])
        XCTAssertEqual(arguments.count, 1)
        XCTAssertTrue(arguments[0].value.hasSuffix("shortened — the whole value is on the machine."))
        XCTAssertLessThan(arguments[0].value.count, huge.count)
    }

    /// A long value gets its own line and a short one does not. A path squeezed
    /// against a label on a phone is a path somebody approves without reading;
    /// a `true` given its own paragraph is the opposite mistake.
    func testBlockAndInlineValuesAreToldApart() {
        XCTAssertFalse(CopilotArgument(name: "flag", value: "true").isBlock)
        XCTAssertTrue(CopilotArgument(name: "cmd",
                                      value: "/Users/someone/Projects/app/node_modules/.bin/vitest run")
            .isBlock)
        XCTAssertTrue(CopilotArgument(name: "text", value: "one\ntwo").isBlock)
    }

    // MARK: - The reader itself

    /// Round-trips of the shapes a tool's arguments are actually made of.
    func testTheReaderHandlesTheShapesArgumentsAreMadeOf() {
        XCTAssertEqual(OrderedJSON.parse("null"), .null)
        XCTAssertEqual(OrderedJSON.parse(" true "), .bool(true))
        XCTAssertEqual(OrderedJSON.parse("-12.5e3"), .number("-12.5e3"))
        XCTAssertEqual(OrderedJSON.parse(#""hi""#), .string("hi"))
        XCTAssertEqual(OrderedJSON.parse("[]"), .array([]))
        XCTAssertEqual(OrderedJSON.parse("{}"), .object([]))
        XCTAssertEqual(OrderedJSON.parse(#"{"a":[1,{"b":null}]}"#)?.json, #"{"a":[1,{"b":null}]}"#)
    }

    /**
     * Malformed input is nil, not a best effort.
     *
     * A parser that ignores what it does not understand is one that accepts two
     * frames concatenated, or a truncated one — and the caller's fallback is
     * honest about being a fallback, which a half-read argument list would not
     * be.
     */
    func testMalformedInputIsRefusedRatherThanGuessedAt() {
        for bad in ["{", "{\"a\"}", "{\"a\":}", "[1,]", "tru", "01", "1.", "\"unterminated",
                    "{\"a\":1} {\"b\":2}", "\"raw\ncontrol\"", #""\uD83D""#] {
            XCTAssertNil(OrderedJSON.parse(bad), "\(bad) is not one JSON document")
        }
    }

    /// A deep frame is refused rather than recursed into. This runs on a socket
    /// callback, and a stack overflow there is a crash in the background where
    /// nobody sees it.
    func testDepthIsBounded() {
        let deep = String(repeating: "[", count: OrderedJSON.maxDepth + 5)
            + String(repeating: "]", count: OrderedJSON.maxDepth + 5)
        XCTAssertNil(OrderedJSON.parse(deep))

        let shallow = String(repeating: "[", count: 8) + String(repeating: "]", count: 8)
        XCTAssertNotNil(OrderedJSON.parse(shallow))
    }

    /// A duplicate key is not drawn twice on a consent sheet. Last one wins,
    /// which is what every other JSON reader in this product does, including
    /// Foundation's — so the two cannot disagree about what was approved.
    func testADuplicateKeyIsDrawnOnce() {
        guard case let .object(members)? = OrderedJSON.parse(#"{"a":1,"b":2,"a":3}"#) else {
            return XCTFail("it should read")
        }
        XCTAssertEqual(members.map(\.name), ["b", "a"])
        XCTAssertEqual(members.last?.value, .number("3"))
    }
}
