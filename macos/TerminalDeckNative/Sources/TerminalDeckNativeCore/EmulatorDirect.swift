import Foundation

// Finding 3, part B (Asad, 22 Oct 2026: "find out a similar way for android too so we save system cost and
// increase user experience"). The Android emulator's own control port, the way Android Studio's embedded
// emulator uses it: gRPC (`EmulatorController`, emulator_controller.proto in the SDK) on a local port
// with the token from the emulator's discovery file. Frames come by shared memory (the emulator writes
// each picture into a file this app owns and maps; the stream only says "a new one is in"); fingers and
// keys go in on one ordered input stream. The pure parts live here so each rule is tested on its own:
// the discovery file, the few protobuf messages, gRPC's message frames, and HTTP/2 frames with
// literal-only request headers. No gRPC library and no generated code: about 300 lines, Apple licence
// free, nothing to install, nothing that needs Node or Python.

// MARK: - The emulator's discovery file

/// One running emulator, from `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`.
public struct EmulatorDiscovery: Equatable, Sendable {
    /// The console port: `emulator-5554` has 5554.
    public var consolePort: Int
    public var grpcPort: Int
    public var token: String
    public var avd: String

    public init(consolePort: Int, grpcPort: Int, token: String, avd: String = "") {
        self.consolePort = consolePort
        self.grpcPort = grpcPort
        self.token = token
        self.avd = avd
    }

    /// The file's `key=value` lines; nil without a console port, a gRPC port or a token.
    public init?(ini: String) {
        var values: [String: String] = [:]
        for raw in ini.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let console = values["port.serial"].flatMap(Int.init), let grpc = values["grpc.port"].flatMap(Int.init),
              (1...65_535).contains(console), (1...65_535).contains(grpc),
              let token = values["grpc.token"], !token.isEmpty,
              token.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
        self.init(consolePort: console, grpcPort: grpc, token: token, avd: values["avd.name"] ?? "")
    }

    /// `emulator-5554` → 5554.
    public static func consolePort(serial: String) -> Int? {
        guard serial.hasPrefix("emulator-") else { return nil }
        return Int(serial.dropFirst("emulator-".count))
    }

    /// The process id in `pid_<pid>.ini`.
    public static func pid(fileName: String) -> Int32? {
        guard fileName.hasPrefix("pid_"), fileName.hasSuffix(".ini") else { return nil }
        return Int32(fileName.dropFirst(4).dropLast(4))
    }
}

// MARK: - The picture files

/// The files the emulator writes its pictures into (about 10 MB each). Each is named after the process that
/// made it, so files left by an app that crashed can be told from files a running copy still uses.
public enum EmulatorFrameFiles {
    public static func name(pid: Int32, id: UUID) -> String { "p\(pid)-\(id.uuidString).rgba" }

    /// The process that made the file; nil for a name not made this way.
    public static func owner(_ fileName: String) -> Int32? {
        guard fileName.hasPrefix("p"), fileName.hasSuffix(".rgba"), let dash = fileName.firstIndex(of: "-") else { return nil }
        guard let pid = Int32(fileName[fileName.index(after: fileName.startIndex)..<dash]), pid > 0 else { return nil }
        return pid
    }

    /// Whether a file found in the folder can go: its maker has ended. A picture file named the first
    /// way (no maker in the name) goes once it is an hour old; anything else in the folder stays.
    public static func unused(fileName: String, age: TimeInterval, alive: (Int32) -> Bool) -> Bool {
        guard fileName.hasSuffix(".rgba") else { return false }
        if let pid = owner(fileName) { return !alive(pid) }
        return UUID(uuidString: String(fileName.dropLast(".rgba".count))) != nil && age > 3_600
    }
}

// MARK: - Protobuf, only what these messages need

public struct ProtoWriter: Sendable {
    public private(set) var data = Data()
    public init() {}

    public mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    public mutating func field(_ number: Int, varint value: UInt64) {
        varint(UInt64(number << 3))
        varint(value)
    }

    /// int32 as protobuf writes it: a negative value as ten bytes, sign-extended.
    public mutating func field(_ number: Int, int32 value: Int32) { field(number, varint: UInt64(bitPattern: Int64(value))) }

    public mutating func field(_ number: Int, bytes: Data) {
        varint(UInt64(number << 3 | 2))
        varint(UInt64(bytes.count))
        data.append(bytes)
    }

    public mutating func field(_ number: Int, string: String) { field(number, bytes: Data(string.utf8)) }
}

/// Reads a message's fields in order, skipping the ones not asked for. Malformed input ends the reading.
public struct ProtoReader {
    public enum Value: Equatable { case varint(UInt64), bytes(Data), fixed64(UInt64), fixed32(UInt32) }
    private let data: Data
    private var index: Data.Index

    public init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    private mutating func readFixed(_ count: Int) -> UInt64? {
        guard data.endIndex - index >= count else { return nil }
        var value: UInt64 = 0
        for offset in 0..<count { value |= UInt64(data[index + offset]) << (8 * UInt64(offset)) }
        index += count
        return value
    }

    public mutating func next() -> (number: Int, value: Value)? {
        guard index < data.endIndex, let key = readVarint() else { return nil }
        let number = Int(truncatingIfNeeded: key >> 3)
        guard number > 0 else { return nil }
        switch key & 7 {
        case 0: return readVarint().map { (number, .varint($0)) }
        case 1: return readFixed(8).map { (number, .fixed64($0)) }
        case 2:
            guard let length = readVarint(), length <= UInt64(data.endIndex - index) else { return nil }
            let start = index
            index += Int(length)
            return (number, .bytes(Data(data[start..<index])))
        case 5: return readFixed(4).map { (number, .fixed32(UInt32($0))) }
        default: return nil
        }
    }
}

// MARK: - The emulator's messages

public enum EmulatorWire {
    public static let service = "/android.emulation.control.EmulatorController/"

    /// `ImageFormat` for a stream of raw RGBA pictures of this size written into `mmapURL`
    /// (`ImageTransport { channel: MMAP, handle }`); no handle asks for the bytes in the reply.
    public static func imageFormat(rgba: Bool, width: Int, height: Int, mmapURL: String?) -> Data {
        var writer = ProtoWriter()
        if rgba { writer.field(1, varint: 1) }   // RGBA8888 (PNG is 0, the default)
        if width > 0 { writer.field(3, varint: UInt64(width)) }
        if height > 0 { writer.field(4, varint: UInt64(height)) }
        if let mmapURL {
            var transport = ProtoWriter()
            transport.field(1, varint: 1)      // MMAP
            transport.field(2, string: mmapURL)
            writer.field(6, bytes: transport.data)
        }
        return writer.data
    }

    /// One `Image` from `getScreenshot` / `streamScreenshot`.
    public struct Image: Equatable, Sendable {
        public var width = 0
        public var height = 0
        /// 0 portrait, 1 landscape, 2 reverse portrait, 3 reverse landscape.
        public var rotation = 0
        public var seq: UInt64 = 0
        /// The picture itself; empty when it went by shared memory.
        public var bytes = Data()
        public init() {}
    }

    public static func image(_ data: Data) -> Image {
        var image = Image()
        var deprecatedWidth = 0, deprecatedHeight = 0
        var reader = ProtoReader(data)
        while let (number, value) = reader.next() {
            switch (number, value) {
            case (1, .bytes(let format)):
                var inner = ProtoReader(format)
                while let (field, item) = inner.next() {
                    switch (field, item) {
                    case (2, .bytes(let rotation)):
                        var rotationReader = ProtoReader(rotation)
                        while let (rotationField, rotationValue) = rotationReader.next() {
                            if rotationField == 1, case .varint(let v) = rotationValue { image.rotation = Int(truncatingIfNeeded: v & 3) }
                        }
                    case (3, .varint(let v)): image.width = Int(truncatingIfNeeded: min(v, 1 << 20))
                    case (4, .varint(let v)): image.height = Int(truncatingIfNeeded: min(v, 1 << 20))
                    default: break
                    }
                }
            case (2, .varint(let v)): deprecatedWidth = Int(truncatingIfNeeded: min(v, 1 << 20))
            case (3, .varint(let v)): deprecatedHeight = Int(truncatingIfNeeded: min(v, 1 << 20))
            case (4, .bytes(let bytes)): image.bytes = bytes
            case (5, .varint(let v)): image.seq = v
            default: break
            }
        }
        if image.width == 0 { image.width = deprecatedWidth }
        if image.height == 0 { image.height = deprecatedHeight }
        return image
    }

    /// A finger on the screen, in the device's own pixels; pressure 0 lifts it.
    public struct Touch: Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var id: Int
        public var down: Bool
        public init(x: Int, y: Int, id: Int, down: Bool) {
            self.x = x
            self.y = y
            self.id = id
            self.down = down
        }
    }

    /// Android Studio's pressure for a finger that is down.
    public static let pressure: Int32 = 1_024

    /// `InputEvent { touch_event: TouchEvent { touches } }`.
    public static func touchEvent(_ touches: [Touch]) -> Data {
        var event = ProtoWriter()
        for touch in touches {
            var one = ProtoWriter()
            one.field(1, int32: Int32(clamping: touch.x))
            one.field(2, int32: Int32(clamping: touch.y))
            one.field(3, int32: Int32(clamping: touch.id))
            one.field(4, int32: touch.down ? pressure : 0)
            event.field(1, bytes: one.data)
        }
        var input = ProtoWriter()
        input.field(2, bytes: event.data)
        return input.data
    }

    /// `InputEvent { key_event: KeyboardEvent { text } }`: printable ASCII typed key by key.
    public static func typeEvent(_ text: String) -> Data {
        var key = ProtoWriter()
        key.field(5, string: text)
        var input = ProtoWriter()
        input.field(1, bytes: key.data)
        return input.data
    }

    /// `InputEvent { key_event: KeyboardEvent { eventType: keypress, key } }`: a named key or button.
    public static func keyEvent(_ name: String) -> Data {
        var key = ProtoWriter()
        key.field(2, varint: 2)   // keypress: down then up
        key.field(4, string: name)
        var input = ProtoWriter()
        input.field(1, bytes: key.data)
        return input.data
    }

    /// The key names the emulator knows (w3c key values, and Android's own phone keys).
    public static func keyName(_ panelKey: String) -> String? {
        switch panelKey {
        case "return", "enter": "Enter"
        case "delete", "backspace": "Backspace"
        case "tab": "Tab"
        case "escape": "Escape"
        case "arrow-up": "ArrowUp"
        case "arrow-down": "ArrowDown"
        case "arrow-left": "ArrowLeft"
        case "arrow-right": "ArrowRight"
        case "home-key": "Home"
        case "end": "End"
        case "page-up": "PageUp"
        case "page-down": "PageDown"
        case "forward-delete": "Delete"
        default: nil
        }
    }

    public static func buttonName(_ button: String) -> String? {
        switch button {
        case "home": "GoHome"
        case "back": "GoBack"
        case "recents", "app-switch", "overview": "AppSwitch"
        case "power", "lock": "Power"
        case "volume-up": "AudioVolumeUp"
        case "volume-down": "AudioVolumeDown"
        default: nil
        }
    }

    /// Text the emulator can type: printable ASCII and nothing else (anything more goes the engine's way).
    public static func typeable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x20..<0x7F).contains($0.value) }
    }

    /// A point on the shown picture (0…1 from the top left) in the device's pixels, upright only: a
    /// turned screen sends its input the engine's way.
    public static func pixel(x: Double, y: Double, width: Int, height: Int) -> (x: Int, y: Int) {
        let cx = x.isFinite ? min(max(x, 0), 1) : 0, cy = y.isFinite ? min(max(y, 0), 1) : 0
        return (min(width - 1, max(0, Int((cx * Double(width)).rounded(.down)))),
                min(height - 1, max(0, Int((cy * Double(height)).rounded(.down)))))
    }

    /// Whether the raw rows run bottom up: the raw picture is compared with a PNG of the same screen
    /// (top row first) both ways, on a sparse grid; the closer way wins. The proto says "bottom up";
    /// this checks rather than trusts it.
    public static func bottomUp(raw: UnsafeRawBufferPointer, png: Data, width: Int, height: Int) -> Bool {
        guard raw.count >= width * height * 4, png.count >= width * height * 4, width > 0, height > 1 else { return false }
        var same = 0, flipped = 0
        png.withUnsafeBytes { picture in
            for r in 0..<24 {
                let row = r * (height - 1) / 23
                for c in 0..<48 {
                    let column = c * (width - 1) / 47
                    for channel in 0..<3 {
                        let rawValue = Int(raw[(row * width + column) * 4 + channel])
                        same += abs(rawValue - Int(picture[(row * width + column) * 4 + channel]))
                        flipped += abs(rawValue - Int(picture[((height - 1 - row) * width + column) * 4 + channel]))
                    }
                }
            }
        }
        return flipped < same
    }
}

// MARK: - gRPC messages

public enum GRPCMessage {
    /// One message as gRPC sends it: not compressed, its length, then the bytes.
    public static func wrap(_ message: Data) -> Data {
        var out = Data([0])
        var length = UInt32(message.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(message)
        return out
    }

    /// Gathers a stream's bytes and hands back whole messages. A compressed message (never asked for)
    /// or one larger than `limit` ends the stream: `failed`.
    public struct Unpacker: Sendable {
        private var buffer = Data()
        public private(set) var failed = false
        public let limit: Int
        public init(limit: Int = 32 << 20) { self.limit = limit }

        public mutating func push(_ bytes: Data) -> [Data] {
            guard !failed else { return [] }
            buffer.append(bytes)
            var out: [Data] = []
            while buffer.count >= 5 {
                let start = buffer.startIndex
                guard buffer[start] == 0 else { failed = true; return out }
                let length = Int(buffer[start + 1]) << 24 | Int(buffer[start + 2]) << 16 | Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
                guard length <= limit else { failed = true; return out }
                guard buffer.count >= 5 + length else { break }
                out.append(Data(buffer[(start + 5)..<(start + 5 + length)]))
                buffer.removeSubrange(start..<(start + 5 + length))
            }
            return out
        }
    }
}

// MARK: - HTTP/2, the part a plaintext local gRPC client needs

public struct H2Frame: Equatable, Sendable {
    public enum Kind: UInt8 { case data = 0, headers = 1, priority = 2, reset = 3, settings = 4, pushPromise = 5,
                              ping = 6, goAway = 7, windowUpdate = 8, continuation = 9 }
    public static let endStream: UInt8 = 0x1
    public static let ack: UInt8 = 0x1
    public static let endHeaders: UInt8 = 0x4
    public static let padded: UInt8 = 0x8
    public static let priorityFlag: UInt8 = 0x20
    public static let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    public var type: UInt8
    public var flags: UInt8
    public var stream: UInt32
    public var payload: Data

    public init(_ kind: Kind, flags: UInt8 = 0, stream: UInt32 = 0, payload: Data = Data()) {
        type = kind.rawValue
        self.flags = flags
        self.stream = stream
        self.payload = payload
    }

    public init(type: UInt8, flags: UInt8, stream: UInt32, payload: Data) {
        self.type = type
        self.flags = flags
        self.stream = stream
        self.payload = payload
    }

    public var kind: Kind? { Kind(rawValue: type) }

    public var encoded: Data {
        var out = Data(capacity: 9 + payload.count)
        let length = payload.count
        out.append(contentsOf: [UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), type, flags])
        let id = stream & 0x7FFF_FFFF
        out.append(contentsOf: [UInt8(id >> 24 & 0xFF), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)])
        out.append(payload)
        return out
    }

    /// SETTINGS with these (identifier, value) pairs.
    public static func settings(_ pairs: [(UInt16, UInt32)]) -> H2Frame {
        var payload = Data()
        for (identifier, value) in pairs {
            payload.append(contentsOf: [UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                                        UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
        return H2Frame(.settings, payload: payload)
    }

    public static func windowUpdate(stream: UInt32, increment: UInt32) -> H2Frame {
        let value = increment & 0x7FFF_FFFF
        return H2Frame(.windowUpdate, stream: stream,
                       payload: Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]))
    }

    /// A SETTINGS frame's pairs.
    public var settingsPairs: [(UInt16, UInt32)] {
        guard kind == .settings, payload.count % 6 == 0 else { return [] }
        var out: [(UInt16, UInt32)] = []
        var index = payload.startIndex
        while index < payload.endIndex {
            let identifier = UInt16(payload[index]) << 8 | UInt16(payload[index + 1])
            let value = UInt32(payload[index + 2]) << 24 | UInt32(payload[index + 3]) << 16 | UInt32(payload[index + 4]) << 8 | UInt32(payload[index + 5])
            out.append((identifier, value))
            index += 6
        }
        return out
    }

    /// A WINDOW_UPDATE frame's increment.
    public var windowIncrement: UInt32? {
        guard kind == .windowUpdate, payload.count == 4 else { return nil }
        let p = payload.startIndex
        return (UInt32(payload[p]) << 24 | UInt32(payload[p + 1]) << 16 | UInt32(payload[p + 2]) << 8 | UInt32(payload[p + 3])) & 0x7FFF_FFFF
    }

    /// A DATA frame's bytes without its padding (nil when the padding is impossible).
    public var dataBytes: Data? {
        guard kind == .data else { return nil }
        guard flags & Self.padded != 0 else { return payload }
        guard let pad = payload.first, Int(pad) < payload.count else { return nil }
        return Data(payload[(payload.startIndex + 1)..<(payload.endIndex - Int(pad))])
    }

    /// Request headers as an HPACK block of literal fields ("without indexing, new name", no Huffman):
    /// valid for any server, no table to keep. Names must be lower case.
    public static func headerBlock(_ fields: [(String, String)]) -> Data {
        var out = Data()
        func integer(_ value: Int) {
            if value < 127 { out.append(UInt8(value)); return }
            out.append(127)
            var rest = value - 127
            while rest >= 128 {
                out.append(UInt8(rest & 0x7F) | 0x80)
                rest >>= 7
            }
            out.append(UInt8(rest))
        }
        for (name, value) in fields {
            out.append(0)
            integer(name.utf8.count)
            out.append(contentsOf: name.utf8)
            integer(value.utf8.count)
            out.append(contentsOf: value.utf8)
        }
        return out
    }
}

/// Splits a byte stream into frames. A frame larger than `maxFrame` breaks the connection: `failed`.
public struct H2FrameParser: Sendable {
    private var buffer = Data()
    public private(set) var failed = false
    public let maxFrame: Int
    public init(maxFrame: Int = 1 << 24) { self.maxFrame = maxFrame }

    public mutating func push(_ bytes: Data) -> [H2Frame] {
        guard !failed else { return [] }
        buffer.append(bytes)
        var out: [H2Frame] = []
        while buffer.count >= 9 {
            let s = buffer.startIndex
            let length = Int(buffer[s]) << 16 | Int(buffer[s + 1]) << 8 | Int(buffer[s + 2])
            guard length <= maxFrame else { failed = true; return out }
            guard buffer.count >= 9 + length else { break }
            let stream = (UInt32(buffer[s + 5]) << 24 | UInt32(buffer[s + 6]) << 16 | UInt32(buffer[s + 7]) << 8 | UInt32(buffer[s + 8])) & 0x7FFF_FFFF
            out.append(H2Frame(type: buffer[s + 3], flags: buffer[s + 4], stream: stream, payload: Data(buffer[(s + 9)..<(s + 9 + length)])))
            buffer.removeSubrange(s..<(s + 9 + length))
        }
        return out
    }
}
