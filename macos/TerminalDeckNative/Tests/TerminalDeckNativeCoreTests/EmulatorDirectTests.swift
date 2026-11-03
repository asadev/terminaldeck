import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// Finding 3, part B: the Android emulator's direct path, its wire rules — the discovery file, the few
/// protobuf messages (field numbers from the SDK's emulator_controller.proto), gRPC message frames and
/// HTTP/2 frames with literal request headers.
@Suite struct EmulatorDirectTests {
    @Test func discoveryFileGivesTheControlPortAndToken() throws {
        let ini = """
        port.serial=5554
        port.adb=5555
        avd.name=ASAD_Pixel8
        grpc.port=8554
        grpc.token=abc+/=123
        grpc.jwks=/tmp/jwks
        """
        let found = try #require(EmulatorDiscovery(ini: ini))
        #expect(found == EmulatorDiscovery(consolePort: 5554, grpcPort: 8554, token: "abc+/=123", avd: "ASAD_Pixel8"))
        #expect(EmulatorDiscovery(ini: "port.serial=5554\ngrpc.port=8554\n") == nil)
        #expect(EmulatorDiscovery(ini: "port.serial=5554\ngrpc.port=0\ngrpc.token=x\n") == nil)
        #expect(EmulatorDiscovery(ini: "port.serial=5554\ngrpc.port=8554\ngrpc.token=a b\n") == nil)
        #expect(EmulatorDiscovery.consolePort(serial: "emulator-5556") == 5556)
        #expect(EmulatorDiscovery.consolePort(serial: "R5CT30ABCDE") == nil)
        #expect(EmulatorDiscovery.pid(fileName: "pid_12345.ini") == 12345)
        #expect(EmulatorDiscovery.pid(fileName: "pid_x.ini") == nil)
    }

    @Test func varintsAndFields() {
        var writer = ProtoWriter()
        writer.field(1, varint: 300)
        #expect(writer.data == Data([0x08, 0xAC, 0x02]))
        var negative = ProtoWriter()
        negative.field(1, int32: -1)
        #expect(negative.data.count == 11)
        var text = ProtoWriter()
        text.field(2, string: "hi")
        #expect(text.data == Data([0x12, 0x02, 0x68, 0x69]))
    }

    @Test func readerSkipsWhatItDoesNotKnowAndStopsOnGarbage() {
        var writer = ProtoWriter()
        writer.field(9, varint: 7)
        writer.field(4, bytes: Data([1, 2, 3]))
        var reader = ProtoReader(writer.data)
        #expect(reader.next()?.number == 9)
        #expect(reader.next()?.value == .bytes(Data([1, 2, 3])))
        #expect(reader.next() == nil)
        var broken = ProtoReader(Data([0x22, 0x05, 0x01]))   // says 5 bytes, has 1
        #expect(broken.next() == nil)
    }

    @Test func screenStreamFormatAsksForRawPicturesInTheFile() {
        let format = EmulatorWire.imageFormat(rgba: true, width: 1080, height: 2400, mmapURL: "file:///tmp/a.rgba")
        var reader = ProtoReader(format)
        var fields: [Int: ProtoReader.Value] = [:]
        while let (number, value) = reader.next() { fields[number] = value }
        #expect(fields[1] == .varint(1))
        #expect(fields[3] == .varint(1080))
        #expect(fields[4] == .varint(2400))
        guard case .bytes(let transport)? = fields[6] else { Issue.record("no transport"); return }
        var inner = ProtoReader(transport)
        #expect(inner.next()?.value == .varint(1))
        #expect(inner.next()?.value == .bytes(Data("file:///tmp/a.rgba".utf8)))
        #expect(EmulatorWire.imageFormat(rgba: false, width: 0, height: 0, mmapURL: nil).isEmpty)
    }

    @Test func imageRepliesAreRead() {
        var rotation = ProtoWriter()
        rotation.field(1, varint: 1)
        var format = ProtoWriter()
        format.field(1, varint: 1)
        format.field(2, bytes: rotation.data)
        format.field(3, varint: 2400)
        format.field(4, varint: 1080)
        var image = ProtoWriter()
        image.field(1, bytes: format.data)
        image.field(4, bytes: Data([9, 9]))
        image.field(5, varint: 42)
        let read = EmulatorWire.image(image.data)
        #expect(read.width == 2400 && read.height == 1080 && read.rotation == 1 && read.seq == 42 && read.bytes == Data([9, 9]))
        var old = ProtoWriter()
        old.field(2, varint: 320)
        old.field(3, varint: 640)
        #expect(EmulatorWire.image(old.data).width == 320)
        #expect(EmulatorWire.image(Data([0xFF])).width == 0)
    }

    @Test func touchesAreInputEventsWithPressure() {
        let event = EmulatorWire.touchEvent([.init(x: 540, y: 1200, id: 0, down: true)])
        var input = ProtoReader(event)
        guard case (2, .bytes(let touchEvent))? = input.next() else { Issue.record("not a touch event"); return }
        var touches = ProtoReader(touchEvent)
        guard case (1, .bytes(let touch))? = touches.next() else { Issue.record("no touch"); return }
        var fields = ProtoReader(touch)
        var values: [Int: UInt64] = [:]
        while let (number, value) = fields.next() { if case .varint(let v) = value { values[number] = v } }
        #expect(values == [1: 540, 2: 1200, 3: 0, 4: 1024])
        let up = EmulatorWire.touchEvent([.init(x: 1, y: 2, id: 1, down: false)])
        #expect(up.last == 0)   // pressure 0 lifts the finger
    }

    @Test func keysTextAndButtons() {
        var typed = ProtoReader(EmulatorWire.typeEvent("ok"))
        guard case (1, .bytes(let keyEvent))? = typed.next() else { Issue.record("not a key event"); return }
        var key = ProtoReader(keyEvent)
        #expect(key.next()?.value == .bytes(Data("ok".utf8)))
        #expect(EmulatorWire.keyName("return") == "Enter")
        #expect(EmulatorWire.keyName("delete") == "Backspace")
        #expect(EmulatorWire.buttonName("home") == "GoHome")
        #expect(EmulatorWire.buttonName("back") == "GoBack")
        #expect(EmulatorWire.buttonName("shake") == nil)
        #expect(EmulatorWire.typeable("Hello, world!"))
        #expect(!EmulatorWire.typeable("سلام"))
        #expect(!EmulatorWire.typeable(""))
    }

    @Test func pointsBecomeDevicePixelsInsideTheScreen() {
        #expect(EmulatorWire.pixel(x: 0.5, y: 0.5, width: 1080, height: 2400) == (540, 1200))
        #expect(EmulatorWire.pixel(x: 1, y: 1, width: 1080, height: 2400) == (1079, 2399))
        #expect(EmulatorWire.pixel(x: -3, y: .nan, width: 1080, height: 2400) == (0, 0))
    }

    @Test func grpcMessagesAreFramedAndUnpackedAcrossPieces() {
        let framed = GRPCMessage.wrap(Data([1, 2, 3]))
        #expect(framed == Data([0, 0, 0, 0, 3, 1, 2, 3]))
        var unpacker = GRPCMessage.Unpacker()
        let both = framed + GRPCMessage.wrap(Data())
        #expect(unpacker.push(both.prefix(4)).isEmpty)
        #expect(unpacker.push(both.dropFirst(4)) == [Data([1, 2, 3]), Data()])
        var compressed = GRPCMessage.Unpacker()
        _ = compressed.push(Data([1, 0, 0, 0, 0]))
        #expect(compressed.failed)
        var huge = GRPCMessage.Unpacker(limit: 10)
        _ = huge.push(Data([0, 0, 0, 1, 0]))
        #expect(huge.failed)
    }

    @Test func http2FramesRoundTrip() {
        let frame = H2Frame(.data, flags: H2Frame.endStream, stream: 3, payload: Data([7, 8]))
        var parser = H2FrameParser()
        let bytes = frame.encoded + H2Frame.settings([(0x4, 1 << 20)]).encoded
        #expect(parser.push(bytes.prefix(5)).isEmpty)
        let frames = parser.push(bytes.dropFirst(5))
        #expect(frames.first == frame)
        #expect(frames.last?.settingsPairs.first?.1 == 1 << 20)
        #expect(H2Frame.windowUpdate(stream: 0, increment: 1000).windowIncrement == 1000)
        let padded = H2Frame(type: 0, flags: H2Frame.padded, stream: 1, payload: Data([2, 5, 6, 0, 0]))
        #expect(padded.dataBytes == Data([5, 6]))
        let badPad = H2Frame(type: 0, flags: H2Frame.padded, stream: 1, payload: Data([9, 1]))
        #expect(badPad.dataBytes == nil)
        var tooBig = H2FrameParser(maxFrame: 4)
        _ = tooBig.push(H2Frame(.data, stream: 1, payload: Data(count: 5)).encoded)
        #expect(tooBig.failed)
    }

    @Test func headerBlockIsLiteralFieldsWithLongLengths() {
        let block = H2Frame.headerBlock([(":path", "/x")])
        #expect(block == Data([0x00, 5]) + Data(":path".utf8) + Data([2]) + Data("/x".utf8))
        let long = String(repeating: "a", count: 200)
        let encoded = H2Frame.headerBlock([("authorization", long)])
        // 127 in the prefix, then 73 continues: 200 - 127.
        #expect(Array(encoded[15...16]) == [127, 73])
    }

    @Test func rowDirectionIsDecidedAgainstThePNG() {
        // A 4x8 picture: green top rows, blue bottom rows; the PNG's pixels come top row first.
        let width = 4, height = 8
        func rows(topDown: Bool) -> Data {
            var bytes = Data()
            for y in 0..<height {
                let row = topDown ? y : height - 1 - y
                let pixel: [UInt8] = row < 2 ? [0, 255, 0, 255] : (row < 4 ? [255, 0, 0, 255] : [0, 0, 255, 255])
                for _ in 0..<width { bytes.append(contentsOf: pixel) }
            }
            return bytes
        }
        let png = rows(topDown: true)
        #expect(rows(topDown: false).withUnsafeBytes { EmulatorWire.bottomUp(raw: $0, png: png, width: width, height: height) })
        #expect(!rows(topDown: true).withUnsafeBytes { EmulatorWire.bottomUp(raw: $0, png: png, width: width, height: height) })
        #expect(!Data(count: 4).withUnsafeBytes { EmulatorWire.bottomUp(raw: $0, png: png, width: width, height: height) })
    }

    @Test func pictureFilesLeftByAnEndedAppAreSwept() {
        let id = UUID()
        let name = EmulatorFrameFiles.name(pid: 4242, id: id)
        #expect(name == "p4242-\(id.uuidString).rgba")
        #expect(EmulatorFrameFiles.owner(name) == 4242)
        #expect(EmulatorFrameFiles.owner("p0-\(id.uuidString).rgba") == nil)
        #expect(EmulatorFrameFiles.owner(id.uuidString + ".rgba") == nil)
        // Its maker still runs (this app or another copy): kept, however old.
        #expect(!EmulatorFrameFiles.unused(fileName: name, age: 86_400) { _ in true })
        // Its maker ended (a crash): swept at once.
        #expect(EmulatorFrameFiles.unused(fileName: name, age: 0) { _ in false })
        // Named the first way (no maker): swept only once an hour old.
        #expect(!EmulatorFrameFiles.unused(fileName: id.uuidString + ".rgba", age: 60) { _ in false })
        #expect(EmulatorFrameFiles.unused(fileName: id.uuidString + ".rgba", age: 7_200) { _ in false })
        // Anything else in the folder stays.
        #expect(!EmulatorFrameFiles.unused(fileName: "notes.txt", age: 86_400) { _ in false })
        #expect(!EmulatorFrameFiles.unused(fileName: "other.rgba", age: 86_400) { _ in false })
    }
}
