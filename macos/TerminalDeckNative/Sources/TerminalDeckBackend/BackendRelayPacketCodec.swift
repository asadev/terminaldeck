import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// The host's multiplexing and MCP packet families. The iOS RelayWire port only
/// covers the one-byte sealed handshake prefix; these are the missing host APIs.
public enum BackendRelayPacketCodec {
    public static let hostPath = "/v1/host"
    public static let guestPath = "/v1/join"
    public static let secretHeader = "x-deck-host-secret"
    public static let defaultRelayURL = "wss://relay.terminaldeck.dev"
    public static let channelBytes = 16
    public static let envelopeHeaderBytes = 17
    public static let maximumPayloadBytes = 96 * 1024
    public static let hostSecretBytes = 32
    public static let mcpPrefix = "/mcp/"
    public static let maximumMCPRequestBytes = 64 * 1024
    public static let mcpReplyChunkBytes = 60 * 1024
    public static let maximumMCPResponseBytes = 8 * 1024 * 1024
    public static let mcpRelayWaitMilliseconds = 150000
    public static let mcpRatePerMinute = 120
    public static let maximumMCPInFlight = 8
    public static let noRequest = Data(repeating: 0, count: 16)
    public static let sealedVersion = RelayWire.sealedVersion
    public static let noiseMessageBytes = 80
    public static let noiseReplyBytes = 48
    public static let handshakeOpenBytes = RelayWire.handshakeOpenBytes
    public static let handshakeReplyBytes = RelayWire.handshakeReplyBytes

    public enum Kind: UInt8, Sendable { case open = 0x01, data = 0x02, close = 0x03, mcpRequest = 0x10, mcpReply = 0x11, mcpCancel = 0x12, mcpReach = 0x13 }
    public struct Envelope: Equatable, Sendable {
        public let type: UInt8
        public let channel: Data
        public let payload: Data
    }
    public enum Handshake: Equatable, Sendable { case message(Data), malformed, wrongVersion }
    public struct MCPRequestHead: Equatable, Sendable {
        public let pathKey: String?
        public let authorization: String?
        public let protocolVersion: String?
        public let userAgent: String?
        public init(pathKey: String?, authorization: String?, protocolVersion: String?, userAgent: String?) {
            self.pathKey = pathKey; self.authorization = authorization; self.protocolVersion = protocolVersion; self.userAgent = userAgent
        }
        public var value: NativeRPCValue { .object([.init("v", .number(1)), .init("pathKey", pathKey.map(NativeRPCValue.string) ?? .null),
            .init("authorization", authorization.map(NativeRPCValue.string) ?? .null), .init("protocolVersion", protocolVersion.map(NativeRPCValue.string) ?? .null),
            .init("userAgent", userAgent.map(NativeRPCValue.string) ?? .null)]) }
    }
    public struct MCPRequest: Equatable, Sendable { public let head: MCPRequestHead; public let body: Data }
    public struct MCPReplyHead: Equatable, Sendable {
        public let status: Int
        public let contentType: String?
        public init(status: Int, contentType: String?) { self.status = status; self.contentType = contentType }
        public var value: NativeRPCValue { .object([.init("status", .number(Double(status))), .init("contentType", contentType.map(NativeRPCValue.string) ?? .null)]) }
    }
    public struct MCPReplySlice: Equatable, Sendable { public let first: Bool; public let last: Bool; public let head: MCPReplyHead?; public let chunk: Data }
    public static let mcpReplyFirst: UInt8 = 1
    public static let mcpReplyLast: UInt8 = 2

    public static func encodeEnvelope(type: UInt8, channel: Data, payload: Data) throws -> Data {
        guard channel.count == 16 else { throw NativeRPCError.invalidArguments("channel id must be 16 bytes") }
        var result = Data([type]); result.append(channel); result.append(payload)
        return result
    }
    public static func encodeEnvelope(kind: Kind, channel: Data, payload: Data) throws -> Data { try encodeEnvelope(type: kind.rawValue, channel: channel, payload: payload) }
    public static func decodeEnvelope(_ frame: Data) -> Envelope? { decode(frame, allowed: [1, 2, 3]) }
    public static func decodeMCPEnvelope(_ frame: Data) -> Envelope? { decode(frame, allowed: [0x10, 0x11, 0x12, 0x13]) }
    /// Socket ingress uses this bound; the source's raw decoders deliberately
    /// leave frame limits to their caller and remain byte-for-byte above.
    public static func decodeBoundedHostPacket(_ frame: Data) -> Envelope? {
        guard frame.count <= envelopeHeaderBytes + maximumPayloadBytes else { return nil }
        return decode(frame, allowed: [1, 2, 3, 0x10, 0x11, 0x12, 0x13, 0x21, 0x23]) // RCV
    }
    private static func decode(_ frame: Data, allowed: Set<UInt8>) -> Envelope? {
        guard frame.count >= 17, let type = frame.first, allowed.contains(type) else { return nil }
        return Envelope(type: type, channel: Data(frame.dropFirst().prefix(16)), payload: Data(frame.dropFirst(17)))
    }

    public static func hostID(for secret: Data) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var result = "", accumulator: UInt32 = 0, bits = 0
        for byte in SHA256.hash(data: secret) {
            accumulator = (accumulator << 8) | UInt32(byte); bits += 8
            while bits >= 5 {
                bits -= 5; result.append(alphabet[Int((accumulator >> bits) & 31)])
                if result.count == 26 { return result }
            }
        }
        return result
    }
    public static func isHostID(_ value: String) -> Bool { value.range(of: #"^[A-HJ-NP-Z2-9]{26}$"#, options: .regularExpression) != nil }
    public static func withSealedVersion(_ message: Data) -> Data { RelayWire.withSealedVersion(message) }
    public static func readSealedHandshake(_ payload: Data, expected: Int) -> Handshake {
        guard payload.count == expected else { return .malformed }
        guard payload.first == sealedVersion else { return .wrongVersion }
        return .message(Data(payload.dropFirst()))
    }

    public static func encodeMCPRequest(head: MCPRequestHead, body: Data) throws -> Data { try withHead(head.value, rest: body) }
    public static func decodeMCPRequest(_ payload: Data) -> MCPRequest? {
        guard let (head, rest) = readHead(payload), head["v"].number == 1 else { return nil }
        return MCPRequest(head: MCPRequestHead(pathKey: head["pathKey"].string, authorization: head["authorization"].string,
            protocolVersion: head["protocolVersion"].string, userAgent: head["userAgent"].string), body: rest)
    }
    public static func encodeMCPReply(flags: UInt8, head: MCPReplyHead?, chunk: Data) throws -> Data {
        var result = Data([flags])
        if flags & mcpReplyFirst != 0 {
            guard let head else { throw NativeRPCError.invalidArguments("the first slice of an MCP reply must carry its head") }
            result.append(try withHead(head.value, rest: chunk))
        } else { result.append(chunk) }
        return result
    }
    public static func decodeMCPReply(_ payload: Data) -> MCPReplySlice? {
        guard let flags = payload.first else { return nil }
        let first = flags & mcpReplyFirst != 0, last = flags & mcpReplyLast != 0
        let rest = Data(payload.dropFirst())
        if !first { return MCPReplySlice(first: false, last: last, head: nil, chunk: rest) }
        guard let (head, chunk) = readHead(rest), let status = head["status"].number,
              status.rounded() == status, status >= 100, status <= 599 else { return nil }
        return MCPReplySlice(first: true, last: last, head: MCPReplyHead(status: Int(status), contentType: head["contentType"].string), chunk: chunk)
    }
    private static func withHead(_ head: NativeRPCValue, rest: Data) throws -> Data {
        let json = try head.encodedJSON()
        guard json.count <= 65535 else { throw NativeRPCError.invalidArguments("an MCP envelope head must fit in 64 KiB") }
        var result = Data([UInt8(json.count >> 8), UInt8(json.count & 255)])
        result.append(json); result.append(rest)
        return result
    }
    private static func readHead(_ payload: Data) -> (NativeRPCValue, Data)? {
        let bytes = Data(payload)
        guard bytes.count >= 2 else { return nil }
        let count = Int(bytes[0]) << 8 | Int(bytes[1])
        guard bytes.count >= 2 + count else { return nil }
        // Buffer.toString('utf8') replaces malformed UTF-8, as String(decoding:)
        // does; metadata is then parsed and shape-checked rather than cast.
        let text = String(decoding: bytes.subdata(in: 2..<2 + count), as: UTF8.self)
        guard let head = try? NativeRPCValue.parseJSON(Data(text.utf8)), head.fields != nil else { return nil }
        return (head, Data(bytes.dropFirst(2 + count)))
    }
    public static let mcpNotFoundStatus = 404
    public static let mcpNotFoundBody = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"Nothing answered at this address. The computer may be off or not connected, or this link may have been turned off.\"}}"
}
