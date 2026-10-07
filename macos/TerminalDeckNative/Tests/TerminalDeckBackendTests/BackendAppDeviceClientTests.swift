import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendAppDeviceFixtureTransport: BackendAppDeviceByteTransport {
    enum Mode: Sendable { case normal, reverse, error, screenshot, drop, screens }
    nonisolated let incoming: AsyncThrowingStream<Data, any Error>
    private nonisolated let output: AsyncThrowingStream<Data, any Error>.Continuation
    private var reader = BackendAppDeviceFrameReader()
    private(set) var requests: [NativeRPCValue] = []
    private let mode: Mode
    private var held: [NativeRPCValue] = []
    private var shots = 0
    init(_ mode: Mode = .normal) {
        self.mode = mode
        var sink: AsyncThrowingStream<Data, any Error>.Continuation!
        incoming = AsyncThrowingStream { sink = $0 }; output = sink
    }
    func send(_ bytes: Data) async throws {
        for frame in try reader.push(bytes) {
            let request = try NativeRPCValue.parseJSON(frame.payload); requests.append(request)
            let method = request["method"].string ?? ""
            if method == "hello" || method == "server.shutdown" {
                try reply(request, result: .object([])); continue
            }
            switch mode {
            case .normal: try reply(request, result: request["params"])
            case .reverse:
                held.append(request)
                if held.count == 2 { for row in held.reversed() { try reply(row, result: row["params"]) }; held.removeAll() }
            case .error:
                let error = BackendAppDeviceParsing.object([("code", .string("DEVICE_NOT_AVAILABLE")), ("message", .string("Device is offline")), ("recoverable", .bool(true))])
                try packet(BackendAppDeviceParsing.object([("id", request["id"]), ("error", error)]))
            case .screenshot:
                shots += 1
                let answer = BackendAppDeviceParsing.object([("id", request["id"]), ("result", BackendAppDeviceParsing.object([("width", .number(Double(shots * 100))), ("height", .number(Double(shots * 200)))]))])
                var wire = try BackendAppDeviceFrames.encode(kind: 2, payload: answer.encodedJSON())
                wire.append(try BackendAppDeviceFrames.encode(kind: 0x20, payload: Data("png-\(shots)".utf8))); output.yield(wire)
            case .drop: output.finish()
            case .screens:
                try reply(request, result: .object([]))
                var wire = try BackendAppDeviceFrames.encode(kind: 0x10, payload: Data([1, 0x64, 0, 0x33]))
                for i in 0..<60 { wire.append(try BackendAppDeviceFrames.encode(kind: 0x11, payload: Data([UInt8(i)]))) }
                output.yield(wire)
            }
        }
    }
    private func reply(_ request: NativeRPCValue, result: NativeRPCValue) throws { try packet(BackendAppDeviceParsing.object([("id", request["id"]), ("result", result)])) }
    private func packet(_ value: NativeRPCValue) throws { output.yield(try BackendAppDeviceFrames.encode(kind: 2, payload: value.encodedJSON())) }
    nonisolated func close() { output.finish() }
}

@Suite("Native SimView client conversation")
struct BackendAppDeviceClientTests {
    @Test func authenticatesFirstWithVersionFourAndRequestedCodec() async throws {
        let transport = BackendAppDeviceFixtureTransport()
        let client = try await BackendAppDeviceCoreClient.attach(transport: transport, token: "fixture-token", codec: "h264", maxFrameRate: 60, maxWidth: 1600, maxHeight: 1600, clock: BackendAppSessionTestPortClock())
        let first = await transport.requests.first
        #expect(first?["method"].string == "hello")
        #expect(first?["protocolVersion"].number == 4)
        #expect(first?["params"]["token"].string == "fixture-token")
        #expect(first?["params"]["codecs"].elements == [.string("h264")])
        #expect(first?["params"]["maxFrameRate"].number == 60)
        #expect(first?["params"]["maxWidth"].number == 1600)
        await client.close()
    }
    @Test func correlatesOutOfOrderAnswersByTheirRequestIDs() async throws {
        let client = try await BackendAppDeviceCoreClient.attach(transport: BackendAppDeviceFixtureTransport(.reverse), token: "fixture", clock: BackendAppSessionTestPortClock())
        async let first = client.request("one", params: BackendAppDeviceParsing.object([("n", .number(1))]))
        async let second = client.request("two", params: BackendAppDeviceParsing.object([("n", .number(2))]))
        let values = try await (first, second)
        #expect(values.0["n"].number == 1)
        #expect(values.1["n"].number == 2)
        await client.close()
    }
    @Test func engineRefusalRetainsStableCodeAndRecoverability() async throws {
        let client = try await BackendAppDeviceCoreClient.attach(transport: BackendAppDeviceFixtureTransport(.error), token: "fixture", clock: BackendAppSessionTestPortClock())
        do { _ = try await client.request("capture.start"); Issue.record("Expected engine refusal") }
        catch let error as BackendAppDeviceEngineError { #expect(error.code == "DEVICE_NOT_AVAILABLE"); #expect(error.recoverable); #expect(error.message == "Device is offline") }
        await client.close()
    }
    @Test func serializesScreenshotsAndAcceptsResponseAndPNGInOneRead() async throws {
        let client = try await BackendAppDeviceCoreClient.attach(transport: BackendAppDeviceFixtureTransport(.screenshot), token: "fixture", clock: BackendAppSessionTestPortClock())
        async let one = client.screenshot()
        async let two = client.screenshot()
        let answers = try await [one, two]
        #expect(Set(answers.map { String(decoding: $0.png, as: UTF8.self) }) == ["png-1", "png-2"])
        for answer in answers {
            let n = String(decoding: answer.png, as: UTF8.self) == "png-1" ? 1.0 : 2.0
            #expect(answer.width == 100 * n)
            #expect(answer.height == 200 * n)
        }
        await client.close()
    }
    @Test func neverDropsCodedPicturesOrReordersConfiguration() async throws {
        let client = try await BackendAppDeviceCoreClient.attach(transport: BackendAppDeviceFixtureTransport(.screens), token: "fixture", codec: "h264", clock: BackendAppSessionTestPortClock())
        _ = try await client.request("capture.preview")
        var iterator = client.events.makeAsyncIterator()
        if case .some(.config(let config)) = await iterator.next() { #expect(config == Data([1, 0x64, 0, 0x33])) }
        else { Issue.record("Expected decoder configuration before pictures") }
        for i in 0..<60 {
            if case .some(.picture(let picture)) = await iterator.next() { #expect(picture == Data([UInt8(i)])) }
            else { Issue.record("Expected every coded picture in order") }
        }
        await client.close()
    }
    @Test func engineDisconnectFailsPendingAndFutureRequests() async throws {
        let client = try await BackendAppDeviceCoreClient.attach(transport: BackendAppDeviceFixtureTransport(.drop), token: "fixture", clock: BackendAppSessionTestPortClock())
        do { _ = try await client.request("capture.start"); Issue.record("Expected connection failure") } catch {}
        let closed = await client.isClosed(); #expect(closed)
        do { _ = try await client.request("anything"); Issue.record("Expected closed-client refusal") }
        catch { #expect(error.localizedDescription == "The simulator engine is not running.") }
    }
}

@Suite("Inventory merge keeps simulator records")
struct BackendAppDeviceInventoryTests {
    @Test func diskFallbackNamesAndFlagsSurviveMissingEngineIOSRows() async {
        let disk = BackendAppDeviceDiskSimulator(udid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "iPhone 18 Pro", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", state: "ready")
        let sources = BackendAppDeviceInventorySources(engineDevices: { [] }, diskSimulators: { [disk] }, avds: { ["ASAD_Pixel8"] }, avdName: { _ in "" })
        let rows = await BackendAppDeviceInventory(sources: sources, clock: BackendAppSessionTestPortClock()).list()
        #expect(rows.count == 2)
        #expect(rows[0]["name"].string == "iPhone 18 Pro")
        #expect(rows[0]["checking"].bool == true)
        #expect(rows[0]["runtime"].string == "iOS 27.0")
        #expect(rows[1]["id"].string == "avd:ASAD_Pixel8")
        #expect(rows[1]["canBoot"].bool == true)
    }
    @Test func runningAVDDeduplicatesOffRowAndUnauthorizedPhoneKeepsItsNote() async throws {
        let emulator = try NativeRPCValue.parseJSON(Data(#"{"id":"android:emulator-5554","platform":"android","kind":"emulator","state":"ready","available":true,"name":"emulator-5554"}"#.utf8))
        let phone = try NativeRPCValue.parseJSON(Data(#"{"id":"android:phone","platform":"android","kind":"physical","state":"unauthorized"}"#.utf8))
        let sources = BackendAppDeviceInventorySources(engineDevices: { [emulator, phone] }, diskSimulators: { [] }, avds: { ["IMATCH_Pixel8"] }, avdName: { _ in "IMATCH_Pixel8" })
        let rows = await BackendAppDeviceInventory(sources: sources, clock: BackendAppSessionTestPortClock()).list()
        #expect(rows.count == 2)
        #expect(rows[0]["name"].string == "IMATCH Pixel8")
        #expect(!rows.contains { $0["id"].string == "avd:IMATCH_Pixel8" })
        #expect(rows[1]["note"].string == "Unlock the phone and allow this computer when it asks.")
    }
}
