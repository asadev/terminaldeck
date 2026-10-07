import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendAppDeviceTestPortTransport: BackendAppDeviceByteTransport {
    enum Mode: Sendable { case plain, reverse, refusal, jpeg, video, shots, disconnect }
    nonisolated let incoming: AsyncThrowingStream<Data, any Error>
    private nonisolated let sink: AsyncThrowingStream<Data, any Error>.Continuation
    private let mode: Mode
    private var reader = BackendAppDeviceFrameReader()
    private(set) var requests: [NativeRPCValue] = []
    private var held: [NativeRPCValue] = []
    private var shots = 0
    private var shotWaits: [(Int, CheckedContinuation<Void, Never>)] = []
    init(_ mode: Mode) { self.mode = mode; var output: AsyncThrowingStream<Data, any Error>.Continuation!; incoming = AsyncThrowingStream { output = $0 }; sink = output }
    func send(_ data: Data) async throws {
        for frame in try reader.push(data) {
            let row = try NativeRPCValue.parseJSON(frame.payload); requests.append(row); let method = row["method"].string ?? ""
            if method == "hello" {
                guard row["params"]["token"].string == String(repeating: "a", count: 64) else { sink.finish(); return }
                try reply(row, .object([])); continue
            }
            if method == "server.shutdown" { try reply(row, .object([])); continue }
            switch mode {
            case .plain: try reply(row, .object([]))
            case .reverse:
                held.append(row)
                if held.count == 2 { for request in held.reversed() { try reply(request, BackendAppSessionTestPortObject([("echo", request["params"]["n"])])) }; held.removeAll() }
            case .refusal:
                let error = BackendAppSessionTestPortObject([("code", .string("DEVICE_NOT_AVAILABLE")), ("message", .string("Device is offline")), ("recoverable", .bool(true))])
                try packet(2, BackendAppSessionTestPortObject([("id", row["id"]), ("error", error)]).encodedJSON())
            case .jpeg:
                try reply(row, BackendAppSessionTestPortObject([("enabled", .bool(true))])); try packet(0x12, Data("frame-1".utf8)); try packet(0x12, Data("frame-2".utf8))
            case .video:
                try reply(row, BackendAppSessionTestPortObject([("enabled", .bool(true))])); try packet(0x10, Data([1, 0x64, 0, 0x33])); try packet(0x11, Data([0, 0, 0, 0, 0, 0, 0, 7, 1, 0xaa]))
            case .shots:
                shots += 1; try reply(row, BackendAppSessionTestPortObject([("frameId", .string(String(shots))), ("width", .number(Double(100 * shots))), ("height", .number(Double(200 * shots))), ("byteLength", .number(3))]))
                let ready = shotWaits.filter { $0.0 <= shots }; shotWaits.removeAll { $0.0 <= shots }; for wait in ready { wait.1.resume() }
            case .disconnect: sink.finish()
            }
        }
    }
    func whenShots(_ count: Int) async { if shots >= count { return }; await withCheckedContinuation { shotWaits.append((count, $0)) } }
    func deliverShot(_ count: Int) throws { try packet(0x20, Data("png-\(count)".utf8)) }
    private func reply(_ row: NativeRPCValue, _ result: NativeRPCValue) throws { try packet(2, BackendAppSessionTestPortObject([("id", row["id"]), ("result", result)]).encodedJSON()) }
    private func packet(_ kind: UInt8, _ data: Data) throws { sink.yield(try BackendAppDeviceFrames.encode(kind: kind, payload: data)) }
    nonisolated func close() { sink.finish() }
}
final class BackendAppDeviceTestPortClient: XCTestCase, @unchecked Sendable {
    private let token = String(repeating: "a", count: 64)
    func testHelloAuthenticatesFirstWithJPEGAndExactDimensions() async throws {
        let fake = BackendAppDeviceTestPortTransport(.plain), client = try await BackendAppDeviceCoreClient.attach(transport: fake, token: token, maxWidth: 1600, maxHeight: 1600, clock: BackendAppSessionTestPortClock())
        let requests = await fake.requests; let first = try XCTUnwrap(requests.first)
        XCTAssertEqual(first["method"].string, "hello"); XCTAssertEqual(first["protocolVersion"].number, 4); XCTAssertEqual(first["params"]["token"].string, token); XCTAssertEqual(first["params"]["codecs"].elements, [.string("mjpeg")]); XCTAssertEqual(first["params"]["maxWidth"].number, 1600); XCTAssertEqual(first["params"]["maxHeight"].number, 1600)
        await client.close()
    }
    func testAnswersCorrelateWhenSecondArrivesFirst() async throws {
        let client = try await BackendAppDeviceCoreClient.attach(transport: BackendAppDeviceTestPortTransport(.reverse), token: token, clock: BackendAppSessionTestPortClock())
        async let a = client.request("one", params: BackendAppSessionTestPortObject([("n", .number(1))])); async let b = client.request("two", params: BackendAppSessionTestPortObject([("n", .number(2))])); let answers = try await (a, b)
        XCTAssertEqual(answers.0, BackendAppSessionTestPortObject([("echo", .number(1))])); XCTAssertEqual(answers.1, BackendAppSessionTestPortObject([("echo", .number(2))])); await client.close()
    }
    func testEngineRefusalRetainsCodeAndRecoverableFlag() async throws {
        let client = try await BackendAppDeviceCoreClient.attach(transport: BackendAppDeviceTestPortTransport(.refusal), token: token, clock: BackendAppSessionTestPortClock())
        do { _ = try await client.request("capture.start"); XCTFail("Expected refusal") } catch let error as BackendAppDeviceEngineError { XCTAssertEqual(error.code, "DEVICE_NOT_AVAILABLE"); XCTAssertTrue(error.recoverable) }
        await client.close()
    }
    func testEveryJPEGDeliveredToConsumer() async throws {
        let client = try await BackendAppDeviceCoreClient.attach(transport: BackendAppDeviceTestPortTransport(.jpeg), token: token, clock: BackendAppSessionTestPortClock()); _ = try await client.request("capture.preview", params: BackendAppSessionTestPortObject([("enabled", .bool(true))]))
        var iterator = client.events.makeAsyncIterator(), seen: [String] = []
        for _ in 0..<2 { if case .some(.jpeg(let data)) = await iterator.next() { seen.append(String(decoding: data, as: UTF8.self)) } }
        XCTAssertEqual(seen, ["frame-1", "frame-2"]); await client.close()
    }
    func testRequestedH264HandshakeAndPacketBytesExact() async throws {
        let fake = BackendAppDeviceTestPortTransport(.video), client = try await BackendAppDeviceCoreClient.attach(transport: fake, token: token, codec: "h264", maxFrameRate: 60, clock: BackendAppSessionTestPortClock())
        let first = await fake.requests.first; XCTAssertEqual(first?["params"]["codecs"].elements, [.string("h264")]); XCTAssertEqual(first?["params"]["maxFrameRate"].number, 60)
        _ = try await client.request("capture.preview", params: BackendAppSessionTestPortObject([("enabled", .bool(true))])); var iterator = client.events.makeAsyncIterator()
        if case .some(.config(let bytes)) = await iterator.next() { XCTAssertEqual(bytes, Data([1, 0x64, 0, 0x33])) } else { XCTFail("Configuration missing") }
        if case .some(.picture(let bytes)) = await iterator.next() { XCTAssertEqual(bytes, Data([0, 0, 0, 0, 0, 0, 0, 7, 1, 0xaa])) } else { XCTFail("Coded picture missing") }; await client.close()
    }
    func testScreenshotsQueuedAndMatchPNGFollowingEachAnswer() async throws {
        let fake = BackendAppDeviceTestPortTransport(.shots), client = try await BackendAppDeviceCoreClient.attach(transport: fake, token: token, clock: BackendAppSessionTestPortClock())
        let first = Task { try await client.screenshot() }; await fake.whenShots(1); let second = Task { try await client.screenshot() }
        try await fake.deliverShot(1); let one = try await first.value; await fake.whenShots(2); try await fake.deliverShot(2); let two = try await second.value
        XCTAssertEqual(String(decoding: one.png, as: UTF8.self), "png-1"); XCTAssertEqual(one.width, 100); XCTAssertEqual(String(decoding: two.png, as: UTF8.self), "png-2"); XCTAssertEqual(two.height, 400); await client.close()
    }
    func testDisconnectClosesAndFailsPendingAndFuture() async throws {
        let client = try await BackendAppDeviceCoreClient.attach(transport: BackendAppDeviceTestPortTransport(.disconnect), token: token, clock: BackendAppSessionTestPortClock())
        do { _ = try await client.request("capture.start"); XCTFail("Expected disconnect") } catch {}
        let closed = await client.isClosed(); XCTAssertTrue(closed)
        var iterator = client.events.makeAsyncIterator(); var reasons: [String] = []
        if case .some(.closed(let reason)) = await iterator.next() { reasons.append(reason) }; let end = await iterator.next(); XCTAssertNil(end)
        XCTAssertEqual(reasons.count, 1)
        do { _ = try await client.request("anything"); XCTFail("Expected closed refusal") } catch { XCTAssertTrue(error.localizedDescription.contains("not running")) }
    }
    func testWrongTokenIsRefusedByFakeEngine() async {
        do { _ = try await BackendAppDeviceCoreClient.attach(transport: BackendAppDeviceTestPortTransport(.plain), token: String(repeating: "b", count: 64), clock: BackendAppSessionTestPortClock()); XCTFail("Wrong token must fail") } catch {}
    }
}
