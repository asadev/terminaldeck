import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class NativeDockerPresentationTests: XCTestCase {
    func testAdvancedSectionsHaveDistinctIdentitiesAndLabels() {
        let sections = NativeDockerSection.allCases
        XCTAssertEqual(sections, [.containers, .images, .volumes, .networks, .projects])
        XCTAssertEqual(Set(sections.map(\.id)).count, 5)
        XCTAssertEqual(Set(sections.map(\.title)).count, 5)
        XCTAssertEqual(Set(sections.map(\.singular)).count, 5)
        XCTAssertEqual(Set(sections.map(\.symbol)).count, 5)
        XCTAssertTrue(sections.allSatisfy { !$0.title.isEmpty && !$0.singular.isEmpty && !$0.symbol.isEmpty })
    }

    func testLogRowLimitKeepsNewestRowsAndCountsEachEviction() {
        var buffer = NativeDockerLogBuffer(maximumLines: 2, maximumBytes: 100)
        buffer.append("one\ntwo\nthree", stream: "stdout")

        XCTAssertEqual(buffer.lines.map(\.text), ["two", "three"])
        XCTAssertEqual(buffer.lines.map(\.stream), ["stdout", "stdout"])
        XCTAssertEqual(buffer.droppedLines, 1)
        XCTAssertEqual(buffer.byteCount, 8)

        buffer.append("four", stream: "stderr")
        XCTAssertEqual(buffer.lines.map(\.text), ["three", "four"])
        XCTAssertEqual(buffer.lines.map(\.stream), ["stdout", "stderr"])
        XCTAssertEqual(buffer.droppedLines, 2)
        XCTAssertEqual(buffer.byteCount, 9)
        XCTAssertEqual(Set(buffer.lines.map(\.id)).count, buffer.lines.count)
    }

    func testLogByteLimitEvictsWholeOldRowsWithoutLosingNewestOutput() {
        var buffer = NativeDockerLogBuffer(maximumLines: 20, maximumBytes: 9)
        buffer.append("alpha\n", stream: "stdout")
        buffer.append("beta\n", stream: "stdout")
        XCTAssertEqual(buffer.byteCount, 9)
        XCTAssertEqual(buffer.droppedLines, 0)

        buffer.append("c\n", stream: "stderr")
        XCTAssertEqual(buffer.lines.map(\.text), ["beta", "c"])
        XCTAssertEqual(buffer.byteCount, 5)
        XCTAssertEqual(buffer.droppedLines, 1)

        buffer.append("delta\n", stream: "stderr")
        XCTAssertEqual(buffer.lines.map(\.text), ["c", "delta"])
        XCTAssertEqual(buffer.byteCount, 6)
        XCTAssertEqual(buffer.droppedLines, 2)
        XCTAssertEqual(buffer.byteCount, buffer.lines.reduce(0) { $0 + $1.text.utf8.count })
        XCTAssertLessThanOrEqual(buffer.byteCount, buffer.maximumBytes)
    }

    func testOversizedASCIILogChunkRetainsItsNewestBytes() {
        var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: 10)
        buffer.append(String(repeating: "a", count: 100) + "NEWEST", stream: "console")

        XCTAssertEqual(buffer.lines.map(\.text), ["aaaaNEWEST"])
        XCTAssertEqual(buffer.lines.first?.stream, "console")
        XCTAssertEqual(buffer.byteCount, 10)
        XCTAssertEqual(buffer.droppedLines, 1)
    }

    func testOversizedUnicodeLogChunkKeepsWholeScalarsWithinByteBudget() {
        let cases: [(sample: String, budget: Int, expected: String)] = [
            ("😀", 9, "😀😀"),
            ("é", 7, "ééé"),
            ("漢", 11, "漢漢漢"),
        ]
        for value in cases {
            var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: value.budget)
            buffer.append(String(repeating: value.sample, count: 100), stream: "stdout")

            XCTAssertEqual(buffer.lines.map(\.text), [value.expected], "Budget \(value.budget) for \(value.sample)")
            XCTAssertEqual(buffer.byteCount, value.expected.utf8.count)
            XCTAssertLessThanOrEqual(buffer.byteCount, value.budget)
            XCTAssertFalse(buffer.lines.contains { $0.text.contains("\u{FFFD}") })
            XCTAssertEqual(buffer.droppedLines, 1)
        }
    }

    func testUnicodeScalarLargerThanBudgetDoesNotBreakBounds() {
        var buffer = NativeDockerLogBuffer(maximumLines: 2, maximumBytes: 3)
        buffer.append("😀😀", stream: "stdout")

        XCTAssertTrue(buffer.lines.isEmpty)
        XCTAssertEqual(buffer.byteCount, 0)
        XCTAssertEqual(buffer.droppedLines, 1)

        buffer.append("ok", stream: "stderr")
        XCTAssertEqual(buffer.lines.map(\.text), ["ok"])
        XCTAssertEqual(buffer.byteCount, 2)
    }

    func testEmptyChunkDoesNothingAndClearResetsRowsBytesAndDrops() {
        var buffer = NativeDockerLogBuffer(maximumLines: 1, maximumBytes: 10)
        buffer.append("first", stream: "stdout")
        buffer.append("next", stream: "stderr")
        let retainedID = buffer.lines.first?.id
        buffer.append("", stream: "console")

        XCTAssertEqual(buffer.lines.map(\.text), ["next"])
        XCTAssertEqual(buffer.lines.first?.id, retainedID)
        XCTAssertEqual(buffer.byteCount, 4)
        XCTAssertEqual(buffer.droppedLines, 1)

        buffer.clear()
        XCTAssertTrue(buffer.lines.isEmpty)
        XCTAssertEqual(buffer.byteCount, 0)
        XCTAssertEqual(buffer.droppedLines, 0)
        XCTAssertEqual(buffer.maximumLines, 1)
        XCTAssertEqual(buffer.maximumBytes, 10)

        buffer.append("again", stream: "console")
        XCTAssertEqual(buffer.lines.map(\.text), ["again"])
        XCTAssertEqual(buffer.byteCount, 5)
        XCTAssertEqual(buffer.droppedLines, 0)
    }

    func testInvalidBufferLimitsStillRetainOnlyOneByteAndRow() {
        var buffer = NativeDockerLogBuffer(maximumLines: 0, maximumBytes: -1)
        XCTAssertEqual(buffer.maximumLines, 1)
        XCTAssertEqual(buffer.maximumBytes, 1)

        buffer.append("a", stream: "stdout")
        buffer.append("b", stream: "stderr")
        XCTAssertEqual(buffer.lines.map(\.text), ["b"])
        XCTAssertEqual(buffer.lines.first?.stream, "stderr")
        XCTAssertEqual(buffer.byteCount, 1)
        XCTAssertEqual(buffer.droppedLines, 1)
    }

    func testSplitChunksFromTheSameStreamJoinExactlyAndKeepTheirRowID() {
        var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: 100)
        buffer.append("hello", stream: "stdout")
        let firstID = buffer.lines.first?.id

        for chunk in [" ", "wor", "ld"] {
            buffer.append(chunk, stream: "stdout")
            XCTAssertEqual(buffer.lines.count, 1)
            XCTAssertEqual(buffer.lines.first?.id, firstID)
        }
        XCTAssertEqual(buffer.lines.map(\.text), ["hello world"])
        XCTAssertEqual(buffer.lines.first?.stream, "stdout")
        XCTAssertEqual(buffer.byteCount, 11)
        XCTAssertEqual(buffer.droppedLines, 0)
    }

    func testInterleavedStreamsJoinOnlyTheirOwnPartialRowsAndKeepSeparateIDs() {
        var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: 100)
        buffer.append("out-", stream: "stdout")
        let stdoutID = buffer.lines.first?.id
        buffer.append("err-", stream: "stderr")
        let stderrID = buffer.lines.last?.id
        XCTAssertNotEqual(stdoutID, stderrID)

        buffer.append("one", stream: "stdout")
        buffer.append("two\n", stream: "stderr")
        buffer.append("\n", stream: "stdout")
        XCTAssertEqual(buffer.lines.map(\.text), ["err-two", "out-one"])
        XCTAssertEqual(buffer.lines.map(\.stream), ["stderr", "stdout"])
        XCTAssertEqual(buffer.lines.last?.id, stdoutID)
        XCTAssertEqual(buffer.lines.first?.id, stderrID)

        buffer.append("next", stream: "stderr")
        XCTAssertEqual(buffer.lines.map(\.text), ["err-two", "out-one", "next"])
        XCTAssertNotEqual(buffer.lines.last?.id, stderrID)
        XCTAssertEqual(buffer.byteCount, 18)
        XCTAssertEqual(buffer.droppedLines, 0)
    }

    func testNewlineFinishesAPartialRowBeforeTheNextChunk() {
        var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: 100)
        buffer.append("first", stream: "stdout")
        let firstID = buffer.lines.first?.id
        buffer.append("\n", stream: "stdout")
        XCTAssertEqual(buffer.lines.map(\.text), ["first"])
        XCTAssertEqual(buffer.lines.first?.id, firstID)

        buffer.append("second", stream: "stdout")
        let secondID = buffer.lines.last?.id
        XCTAssertNotEqual(secondID, firstID)
        buffer.append(" half\nthird", stream: "stdout")

        XCTAssertEqual(buffer.lines.map(\.text), ["first", "second half", "third"])
        XCTAssertEqual(buffer.lines[1].id, secondID)
        XCTAssertNotEqual(buffer.lines.last?.id, secondID)
        XCTAssertEqual(buffer.byteCount, 21)
        XCTAssertEqual(buffer.droppedLines, 0)
    }

    func testBlankLinesAreRetainedWithoutAddingAnExtraTrailingRow() {
        var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: 100)
        buffer.append("a\n\nb\n\n", stream: "console")

        XCTAssertEqual(buffer.lines.map(\.text), ["a", "", "b", ""])
        XCTAssertEqual(buffer.byteCount, 2)
        XCTAssertEqual(buffer.droppedLines, 0)

        buffer.append("\n", stream: "console")
        XCTAssertEqual(buffer.lines.map(\.text), ["a", "", "b", "", ""])
        XCTAssertEqual(Set(buffer.lines.map(\.id)).count, 5)
        XCTAssertEqual(buffer.byteCount, 2)
    }

    func testCompletedRowsAtExactByteBudgetDoNotLoseContentToLineEndings() {
        for ending in ["\n", "\r\n"] {
            var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: 4)
            buffer.append("test" + ending, stream: "stdout")

            XCTAssertEqual(buffer.lines.map(\.text), ["test"], "Line ending \(ending.debugDescription)")
            XCTAssertEqual(buffer.byteCount, 4)
            XCTAssertEqual(buffer.droppedLines, 0)

            buffer.append("\n", stream: "stdout")
            XCTAssertEqual(buffer.lines.map(\.text), ["test", ""])
            XCTAssertEqual(buffer.byteCount, 4)
            XCTAssertEqual(buffer.droppedLines, 0)
        }
    }

    func testLargeBlankLineChunkRetainsOnlyNewestRowsAndReportsDroppedOutput() {
        var buffer = NativeDockerLogBuffer(maximumLines: 2, maximumBytes: 4)
        buffer.append(String(repeating: "\n", count: 20_000), stream: "console")

        XCTAssertEqual(buffer.lines.map(\.text), ["", ""])
        XCTAssertEqual(buffer.lines.map(\.stream), ["console", "console"])
        XCTAssertEqual(Set(buffer.lines.map(\.id)).count, 2)
        XCTAssertEqual(buffer.byteCount, 0)
        XCTAssertGreaterThan(buffer.droppedLines, 0)
        let dropsAfterLargeChunk = buffer.droppedLines

        buffer.append("tail\n", stream: "console")
        XCTAssertEqual(buffer.lines.map(\.text), ["", "tail"])
        XCTAssertEqual(buffer.byteCount, 4)
        XCTAssertLessThanOrEqual(buffer.lines.count, buffer.maximumLines)
        XCTAssertGreaterThan(buffer.droppedLines, dropsAfterLargeChunk)
    }

    func testCRLFIsRecognizedInOneChunkAndAcrossSplitChunks() {
        var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: 100)
        buffer.append("one\r\ntwo\r\n\r\n", stream: "console")
        XCTAssertEqual(buffer.lines.map(\.text), ["one", "two", ""])
        XCTAssertEqual(buffer.byteCount, 6)

        buffer.clear()
        buffer.append("split\r", stream: "console")
        let rowID = buffer.lines.first?.id
        XCTAssertEqual(buffer.lines.map(\.text), ["split"])
        buffer.append("\nnext\r\n", stream: "console")

        XCTAssertEqual(buffer.lines.map(\.text), ["split", "next"])
        XCTAssertEqual(buffer.lines.first?.id, rowID)
        XCTAssertNotEqual(buffer.lines.last?.id, rowID)
        XCTAssertEqual(buffer.byteCount, 9)
        XCTAssertEqual(buffer.droppedLines, 0)
    }

    func testSplitCRLFAtExactPayloadLimitKeepsContentAndStableRowID() {
        for (content, budget) in [("test", 4), ("😀😀", 8)] {
            for chunks in [[content + "\r", "\n"], [content, "\r\n"], [content, "\r", "\n"]] {
                var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: budget)
                var rowID: UUID?
                for (index, chunk) in chunks.enumerated() {
                    buffer.append(chunk, stream: "stdout")
                    if index == 0 { rowID = buffer.lines.first?.id }
                    XCTAssertEqual(buffer.lines.first?.id, rowID)
                    XCTAssertLessThanOrEqual(buffer.byteCount, budget)
                    XCTAssertEqual(buffer.byteCount, buffer.lines.reduce(0) { $0 + $1.text.utf8.count })
                }
                XCTAssertEqual(buffer.lines.map(\.text), [content])
                XCTAssertEqual(buffer.byteCount, budget)
                XCTAssertEqual(buffer.droppedLines, 0)
            }
        }
    }

    func testPendingCarriageReturnBecomesContentWhenTheNextChunkIsNotNewline() {
        var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: 20)
        buffer.append("abc\r", stream: "console")
        let rowID = buffer.lines.first?.id
        XCTAssertEqual(buffer.lines.map(\.text), ["abc"])
        XCTAssertEqual(buffer.byteCount, 3)

        buffer.append("x\n", stream: "console")
        XCTAssertEqual(buffer.lines.map(\.text), ["abc\rx"])
        XCTAssertEqual(buffer.lines.first?.id, rowID)
        XCTAssertEqual(buffer.byteCount, 5)
        XCTAssertEqual(buffer.droppedLines, 0)
    }

    func testManyStreamsStayWithinBothBoundsAndEvictedFragmentsDoNotReturn() {
        var buffer = NativeDockerLogBuffer(maximumLines: 3, maximumBytes: 10)
        var firstID: UUID?
        for index in 0..<1_000 {
            buffer.append("😀\r", stream: "stream-\(index)")
            if index == 0 { firstID = buffer.lines.first?.id }
            XCTAssertLessThanOrEqual(buffer.lines.count, buffer.maximumLines)
            XCTAssertLessThanOrEqual(buffer.byteCount, buffer.maximumBytes)
            XCTAssertEqual(buffer.byteCount, buffer.lines.reduce(0) { $0 + $1.text.utf8.count })
            XCTAssertEqual(Set(buffer.lines.map(\.id)).count, buffer.lines.count)
        }
        XCTAssertEqual(buffer.lines.map(\.stream), ["stream-998", "stream-999"])
        XCTAssertEqual(buffer.byteCount, 8)
        XCTAssertEqual(buffer.droppedLines, 998)

        buffer.append("\n", stream: "stream-0")
        XCTAssertEqual(buffer.lines.last?.text, "")
        XCTAssertNotEqual(buffer.lines.last?.id, firstID)
        buffer.append("fresh", stream: "stream-0")
        XCTAssertEqual(buffer.lines.map(\.text), ["😀", "", "fresh"])
        XCTAssertEqual(buffer.byteCount, 9)
        XCTAssertEqual(buffer.droppedLines, 999)
    }

    func testBatchEvictionRemovesAllDiscardedStreamsOpenFragments() {
        var buffer = NativeDockerLogBuffer(maximumLines: 3, maximumBytes: 100)
        buffer.append("old-a\r", stream: "a")
        buffer.append("old-b\r", stream: "b")
        buffer.append("old-c\r", stream: "c")
        let discardedIDs = Set(buffer.lines.map(\.id))

        buffer.append("1\n2\n3\n", stream: "console")
        XCTAssertEqual(buffer.lines.map(\.text), ["1", "2", "3"])
        XCTAssertEqual(buffer.byteCount, 3)
        XCTAssertEqual(buffer.droppedLines, 3)

        buffer.append("tail", stream: "a")
        XCTAssertEqual(buffer.lines.map(\.text), ["2", "3", "tail"])
        XCTAssertTrue(discardedIDs.isDisjoint(with: Set(buffer.lines.map(\.id))))
        XCTAssertEqual(buffer.byteCount, 6)
        XCTAssertEqual(buffer.droppedLines, 4)
    }

    func testInterleavedContinuationRetainsNewestOutputDuringByteEviction() {
        var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: 10)
        buffer.append("abc", stream: "stdout")
        let partialID = buffer.lines.first?.id
        buffer.append("12345\n", stream: "stderr")
        buffer.append("defgh", stream: "stdout")

        XCTAssertEqual(buffer.lines.map(\.text), ["abcdefgh"])
        XCTAssertEqual(buffer.lines.first?.id, partialID)
        XCTAssertEqual(buffer.lines.first?.stream, "stdout")
        XCTAssertEqual(buffer.byteCount, 8)
        XCTAssertEqual(buffer.droppedLines, 1)

        buffer.append("\n", stream: "stdout")
        buffer.append("x\n", stream: "stderr")
        XCTAssertEqual(buffer.lines.map(\.text), ["abcdefgh", "x"])
        XCTAssertEqual(buffer.lines.first?.id, partialID)
        XCTAssertEqual(buffer.byteCount, 9)
        XCTAssertLessThanOrEqual(buffer.byteCount, buffer.maximumBytes)
    }

    func testJoinedOversizedUnicodePartialKeepsItsIDAndCompleteNewestScalars() {
        var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: 9)
        buffer.append("😀", stream: "stdout")
        let rowID = buffer.lines.first?.id
        // Each chunk fits; the joined partial row is larger than the byte budget.
        buffer.append("😀😀", stream: "stdout")

        XCTAssertEqual(buffer.lines.map(\.text), ["😀😀"])
        XCTAssertEqual(buffer.lines.first?.id, rowID)
        XCTAssertEqual(buffer.byteCount, 8)
        XCTAssertLessThanOrEqual(buffer.byteCount, buffer.maximumBytes)
        XCTAssertEqual(buffer.droppedLines, 1)
        XCTAssertFalse(buffer.lines.contains { $0.text.contains("\u{FFFD}") })

        buffer.append("x", stream: "stdout")
        XCTAssertEqual(buffer.lines.map(\.text), ["😀😀x"])
        XCTAssertEqual(buffer.lines.first?.id, rowID)
        XCTAssertEqual(buffer.byteCount, 9)
    }

    func testClearResetsEveryStreamsOpenFragmentBeforeNewOutput() {
        var buffer = NativeDockerLogBuffer(maximumLines: 10, maximumBytes: 100)
        buffer.append("old-out\r", stream: "stdout")
        buffer.append("old-err\r", stream: "stderr")
        let previousIDs = Set(buffer.lines.map(\.id))
        buffer.clear()

        buffer.append("new", stream: "stdout")
        buffer.append("next", stream: "stderr")
        buffer.append("-out\n", stream: "stdout")
        buffer.append("-err\n", stream: "stderr")

        XCTAssertEqual(buffer.lines.map(\.text), ["new-out", "next-err"])
        XCTAssertEqual(buffer.lines.map(\.stream), ["stdout", "stderr"])
        XCTAssertTrue(previousIDs.isDisjoint(with: Set(buffer.lines.map(\.id))))
        XCTAssertEqual(buffer.byteCount, 15)
        XCTAssertEqual(buffer.droppedLines, 0)
    }

    func testStreamGenerationRejectsEveryTokenBeforeTheLatestInvalidation() {
        var generation = NativeDockerStreamGeneration()
        let initial = generation.token
        XCTAssertTrue(generation.accepts(initial))

        let next = generation.invalidate()
        XCTAssertNotEqual(next, initial)
        XCTAssertEqual(generation.token, next)
        XCTAssertFalse(generation.accepts(initial))
        XCTAssertTrue(generation.accepts(next))

        let current = generation.invalidate()
        XCTAssertFalse(generation.accepts(initial))
        XCTAssertFalse(generation.accepts(next))
        XCTAssertTrue(generation.accepts(current))
        XCTAssertFalse(generation.accepts(NativeDockerStreamGeneration().token))
    }

    func testUsageRejectsInvalidCPUWithoutDiscardingMemoryReadings() {
        let invalid: [Double] = [-0.1, -100, .infinity, -.infinity, .nan]
        for cpu in invalid {
            let usage = NativeDockerUsage(cpuPercent: cpu, memoryBytes: 4_096, memoryLimitBytes: 8_192)
            XCTAssertNil(usage.cpuPercent)
            XCTAssertEqual(usage.memoryBytes, 4_096)
            XCTAssertEqual(usage.memoryLimitBytes, 8_192)
        }

        let unknown = NativeDockerUsage(cpuPercent: nil, memoryBytes: nil, memoryLimitBytes: nil)
        XCTAssertNil(unknown.cpuPercent)
        XCTAssertNil(unknown.memoryBytes)
        XCTAssertNil(unknown.memoryLimitBytes)
    }

    func testUsagePreservesValidCPUAboveOneHundredPercentForMultipleCores() {
        for cpu in [0.0, 42.25, 100.0, 245.75] {
            let usage = NativeDockerUsage(cpuPercent: cpu, memoryBytes: 0, memoryLimitBytes: nil)
            XCTAssertEqual(usage.cpuPercent, cpu)
            XCTAssertEqual(usage.memoryBytes, 0)
            XCTAssertNil(usage.memoryLimitBytes)
        }
    }
}
