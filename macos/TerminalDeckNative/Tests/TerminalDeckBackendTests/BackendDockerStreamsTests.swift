import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Docker stream framing and output safety", .timeLimit(.minutes(1)))
struct BackendDockerStreamsTests {
    @Test func multiplexHeaderPayloadAndUTF8SurviveEverySingleByteBoundary() throws {
        let message = "hello 🐳 café\n"
        let bytes = frame(1, Data(message.utf8)) + frame(2, Data("warning\n".utf8))
        var parser = try BackendDockerStreams.LogParser(tty: false)
        var records: [BackendDockerStreams.LogRecord] = []
        for byte in bytes { records += try parser.consume(Data([byte])) }
        records += try parser.finish()
        #expect(records.filter { $0.source == "stdout" }.map(\.text).joined() == message)
        #expect(records.filter { $0.source == "stderr" }.map(\.text).joined() == "warning\n")
    }

    @Test func stdinFramesUseStdoutAndTTYBytesAreNotDemultiplexed() throws {
        var multiplexed = try BackendDockerStreams.LogParser(tty: false)
        #expect(try multiplexed.consume(frame(0, Data("input".utf8))).first?.source == "stdout")
        var tty = try BackendDockerStreams.LogParser(tty: true)
        let raw = Data("\u{1b}[31mready\r\n".utf8)
        #expect(try tty.consume(raw) == [.init(source: "console", text: String(decoding: raw, as: UTF8.self))])
    }

    @Test func secretsAreMaskedAcrossFramesAndAcrossEveryPossibleByteSplit() throws {
        let secret = "p🐳ss-token"
        let original = "before " + secret + " after"
        let data = Data(original.utf8)
        for split in 0...data.count {
            var parser = try BackendDockerStreams.LogParser(tty: false, secretValues: [secret])
            let first = try parser.consume(frame(1, Data(data.prefix(split))))
            let second = try parser.consume(frame(1, Data(data.dropFirst(split))))
            let tail = try parser.finish()
            let text = (first + second + tail).map(\.text).joined()
            #expect(text == "before •••••• after")
            #expect(!first.map(\.text).joined().contains(secret))
        }
    }

    @Test func sharedSecretPrefixesStayPrivateAndMaskAtEOF() throws {
        var masker = try BackendDockerStreams.SecretMasker(secretValues: ["abc", "abcdef"])
        #expect(try masker.consume(Data("abc".utf8)).isEmpty)
        #expect(String(decoding: masker.finish(), as: UTF8.self) == "••••••")
        var longest = try BackendDockerStreams.SecretMasker(secretValues: ["abc", "abcdef"])
        let prefix = try longest.consume(Data("abc".utf8))
        let suffix = try longest.consume(Data("def!".utf8))
        #expect(String(decoding: prefix + suffix + longest.finish(), as: UTF8.self) == "••••••!")
    }

    @Test func byteMaskerPreservesANSIAndNonUTF8TerminalBytes() throws {
        var masker = try BackendDockerStreams.SecretMasker(secretValues: ["secret"])
        let first = try masker.consume(Data([0x1b, 0x5b, 0x32, 0x4a, 0xff]) + Data("sec".utf8))
        let last = try masker.consume(Data("ret".utf8)) + masker.finish()
        #expect(first + last == Data([0x1b, 0x5b, 0x32, 0x4a, 0xff]) + Data("••••••".utf8))
    }

    @Test func invalidTruncatedAndOversizedFramesFailClearly() throws {
        var invalid = try BackendDockerStreams.LogParser(tty: false)
        #expect(throws: NativeRPCError.self) { try invalid.consume(Data([1, 1, 0, 0, 0, 0, 0, 0])) }
        var partial = try BackendDockerStreams.LogParser(tty: false)
        _ = try partial.consume(Data([1, 0, 0]))
        #expect(throws: NativeRPCError.self) { try partial.finish() }
        var large = try BackendDockerStreams.LogParser(tty: false, maximumFrameBytes: 16)
        do {
            _ = try large.consume(Data([1, 0, 0, 0, 0, 0, 0, 17]))
            Issue.record("Oversized frame was accepted")
        } catch let error as NativeRPCError { #expect(error.code == "docker-stream-overflow") }
    }

    @Test func jsonLinesAreIncrementalStrictBoundedAndPermitFinalObjectWithoutNewline() throws {
        var parser = try BackendDockerStreams.JSONLineParser(maximumLineBytes: 32)
        #expect(try parser.consume(Data("{\"a\":1}\r\n{\"b\":".utf8)) == [.object([.init("a", .number(1))])])
        #expect(try parser.consume(Data("2}".utf8)).isEmpty)
        #expect(try parser.finish() == [.object([.init("b", .number(2))])])
        var invalid = try BackendDockerStreams.JSONLineParser()
        #expect(throws: NativeRPCError.self) { try invalid.consume(Data("[1]\n".utf8)) }
        var oversized = try BackendDockerStreams.JSONLineParser(maximumLineBytes: 4)
        #expect(throws: NativeRPCError.self) { try oversized.consume(Data("12345".utf8)) }
    }

    @Test func statsUseCPUCounterDeltasCacheAndAllInterfaces() throws {
        let raw = try NativeRPCValue.parseJSON(Data(#"{"cpu_stats":{"cpu_usage":{"total_usage":300,"percpu_usage":[1,2]},"system_cpu_usage":2000,"online_cpus":2},"precpu_stats":{"cpu_usage":{"total_usage":100},"system_cpu_usage":1000},"memory_stats":{"usage":1000,"limit":2000,"stats":{"total_inactive_file":200}},"networks":{"eth0":{"rx_bytes":3,"tx_bytes":4},"eth1":{"rx_bytes":5,"tx_bytes":6}},"blkio_stats":{"io_service_bytes_recursive":[{"op":"Read","value":11},{"op":"Write","value":12},{"op":"Total","value":23}]},"pids_stats":{"current":7}}"#.utf8))
        var parser = BackendDockerStreams.StatsParser()
        let value = try parser.record(raw)
        #expect(value["cpuPercent"].number == 40)
        #expect(value["memoryBytes"].number == 800 && value["memoryPercent"].number == 40)
        #expect(value["networkRxBytes"].number == 8 && value["networkTxBytes"].number == 10)
        #expect(value["blockReadBytes"].number == 11 && value["blockWriteBytes"].number == 12 && value["pids"].number == 7)
        let v2 = raw.setting("memory_stats", .object([.init("usage", .number(100)), .init("limit", .number(0)), .init("stats", .object([.init("inactive_file", .number(25))]))]))
        let zero = try parser.record(v2.setting("precpu_stats", v2["cpu_stats"]))
        #expect(zero["cpuPercent"].number == 0 && zero["memoryBytes"].number == 75 && zero["memoryPercent"].number == 0)
    }

    @Test func eventAttributesAndKnownValuesAreProtectedWithoutRawInspectLeaks() throws {
        let raw = try NativeRPCValue.parseJSON(Data(#"{"Type":"container","Action":"die","Actor":{"ID":"container-one","Attributes":{"name":"demo","TOKEN":"do-not-show","label":"prefix needle suffix","address":"postgres://user:danger@host","session.cookie":"opaque"}},"time":4,"timeNano":5,"private":"ignored"}"#.utf8))
        let safe = try BackendDockerStreams.eventRecord(raw, secretValues: ["needle"])
        #expect(safe["attributes"]["TOKEN"].string == "••••••")
        #expect(safe["attributes"]["label"].string == "prefix •••••• suffix")
        #expect(safe["attributes"]["address"].string == "••••••" && safe["attributes"]["session.cookie"].string == "••••••")
        #expect(safe["id"].string == "container-one" && safe["private"].isNullish)
        #expect(!safe.compact.contains("do-not-show") && !safe.compact.contains("needle"))
    }

    @Test func cancellationEndsAWaitingTransformAndClosesUnderlyingSource() async throws {
        let source = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
        let closed = BackendDockerStreamsTestSignal()
        let response = BackendDockerByteStream(status: 200, headers: [:], data: source.stream, cancel: { closed.mark(); source.continuation.finish() })
        let transformed = try BackendDockerStreams.logs(response: response, tty: true)
        transformed.cancel()
        do {
            for try await _ in transformed.records { Issue.record("A cancelled empty stream emitted output") }
            Issue.record("Cancellation did not throw")
        } catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(closed.value)
    }

    @Test func fullOutputQueueThrowsAndCancelsRatherThanDroppingRecords() async throws {
        let source = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
        let cancelled = BackendDockerStreamsAsyncSignal()
        let response = BackendDockerByteStream(status: 200, headers: [:], data: source.stream, cancel: {
            source.continuation.finish()
            Task { await cancelled.mark() }
        })
        var burst = Data()
        for _ in 0...BackendDockerStreams.maximumQueuedRecords { burst.append(frame(1, Data("x".utf8))) }
        source.continuation.yield(burst)
        let transformed = try BackendDockerStreams.logs(response: response, tty: false)
        // Do not consume until the parser has filled its queue and closed its
        // source. This makes the overflow fixture deterministic without sleeps.
        await cancelled.wait()
        var count = 0
        do {
            for try await _ in transformed.records { count += 1 }
            Issue.record("The full queue ended without an overflow error")
        } catch let error as NativeRPCError { #expect(error.code == "docker-stream-overflow") }
        #expect(count == BackendDockerStreams.maximumQueuedRecords)
    }

    @Test func statsFallBackToPreviousSampleAndRejectPartialRecords() throws {
        let first = try NativeRPCValue.parseJSON(Data(#"{"cpu_stats":{"cpu_usage":{"total_usage":200,"percpu_usage":[1,1]},"system_cpu_usage":1000},"memory_stats":{"usage":500,"limit":1000,"stats":{"cache":100}}}"#.utf8))
        let second = first.setting("cpu_stats", .object([.init("cpu_usage", .object([.init("total_usage", .number(300)), .init("percpu_usage", .array([.number(1), .number(1)]))])), .init("system_cpu_usage", .number(1500))]))
        var parser = BackendDockerStreams.StatsParser()
        #expect(try parser.record(first)["cpuPercent"].number == 0)
        let value = try parser.record(second)
        #expect(value["cpuPercent"].number == 40 && value["memoryBytes"].number == 400)
        #expect(throws: NativeRPCError.self) { try parser.record(.object([])) }
    }

    @Test func EOFDeliversUTF8TailThenClosesUnderlyingSourceExactlyOnce() async throws {
        let source = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let closed = BackendDockerStreamsTestSignal()
        let response = BackendDockerByteStream(status: 200, headers: [:], data: source.stream, cancel: { closed.mark() })
        let transformed = try BackendDockerStreams.logs(response: response, tty: true, secretValues: ["abcd"])
        source.continuation.yield(Data("hello ab".utf8))
        source.continuation.finish()
        var text = ""
        for try await record in transformed.records { text += record["text"].string ?? "" }
        #expect(text == "hello ab")
        transformed.cancel(); transformed.cancel()
        #expect(closed.count == 1)
    }

    private func frame(_ type: UInt8, _ payload: Data) -> Data {
        let count = UInt32(payload.count)
        return Data([type, 0, 0, 0, UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + payload
    }
}

private final class BackendDockerStreamsTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var marks = 0
    func mark() { lock.lock(); marks += 1; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return marks > 0 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return marks }
}

private actor BackendDockerStreamsAsyncSignal {
    private var marked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func mark() {
        marked = true
        let waiters = waiters; self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func wait() async {
        if marked { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
