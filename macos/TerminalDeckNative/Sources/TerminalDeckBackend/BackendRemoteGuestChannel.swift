import Foundation
import TerminalDeckNativeCore

/// Initiator direction of the same shared Noise IK implementation. Counters
/// remain inside one actor; pending handshake state cannot be reused by callers.
public actor BackendRemoteGuestChannel {
    private let relayURL: String
    private let hostID: String
    private let hostKey: Data
    private let identity: BackendSealedIdentity
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var sealed: SealedTransport?
    private var closed = false
    public init(relayURL: String, hostID: String, hostKey: Data, identity: BackendSealedIdentity) {
        self.relayURL = relayURL; self.hostID = hostID; self.hostKey = hostKey; self.identity = identity
    }
    public func open(timeoutMilliseconds: Int = 15000) async throws {
        guard socket == nil, !closed, BackendRelayPacketCodec.isHostID(hostID), hostKey.count == 32 else { throw NativeRPCError.invalidArguments("The remote host identity or channel lifecycle is invalid") }
        let target = try BackendRemoteRelayClient.target(relayURL)
        var components = URLComponents(url: target, resolvingAgainstBaseURL: false)!
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = prefix + "/v1/join"
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "host", value: hostID)]
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = Double(timeoutMilliseconds) / 1000; config.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: components.url!); socket.maximumMessageSize = 98304
        self.session = session; self.socket = socket
        do {
            let guest = StaticKeyPair(privateKey: identity.privateKey)!
            let started = try SealedHandshake.start(deviceStatic: guest, responderStaticPublic: hostKey)
            socket.resume()
            try await socket.send(.data(BackendRelayPacketCodec.withSealedVersion(started.message)))
            let answer = try await timedReceive(socket, milliseconds: timeoutMilliseconds)
            guard case .data(let reply) = answer else { throw BackendSealedFailure.authentication }
            switch BackendRelayPacketCodec.readSealedHandshake(reply, expected: 49) {
            case .message(let bytes): sealed = try SealedHandshake.finish(pending: started.pending, reply: bytes)
            case .malformed: throw BackendSealedFailure.length
            case .wrongVersion: throw BackendSealedFailure.version
            }
            guard !closed else { throw CancellationError() }
        } catch { await close(); throw error }
    }
    public func send(_ value: NativeRPCValue) async throws { try await sendText(String(decoding: value.encodedJSON(), as: UTF8.self)) }
    public func sendText(_ text: String) async throws {
        guard !closed, let socket, let sealed else { throw NativeRPCError(code: "machine-offline", message: "The remote machine's sealed channel is closed") }
        let bytes = try sealed.send(Data(text.utf8))
        guard bytes.count <= 98304 else { throw NativeRPCError(code: "machine-frame", message: "The remote frame is too large") }
        try await socket.send(.data(bytes))
    }
    public func receive(timeoutMilliseconds: Int? = nil) async throws -> String {
        guard !closed, let socket, let sealed else { throw NativeRPCError(code: "machine-offline", message: "The remote machine's sealed channel is closed") }
        let message: URLSessionWebSocketTask.Message
        if let timeoutMilliseconds { message = try await timedReceive(socket, milliseconds: timeoutMilliseconds) }
        else { message = try await withTaskCancellationHandler { try await socket.receive() } onCancel: { socket.cancel(with: .goingAway, reason: nil) } }
        guard !closed else { throw CancellationError() }
        guard case .data(let bytes) = message else { throw NativeRPCError.malformed("The relay delivered an unsealed message") }
        let clear = try sealed.receive(bytes)
        guard clear.count <= 93528, let text = String(data: clear, encoding: .utf8) else { throw NativeRPCError.malformed("The sealed message is not bounded UTF-8") }
        return text
    }
    public func ping() async throws { guard let socket, !closed else { throw CancellationError() }; try await socket.backendSendPing() }
    public func close() {
        guard !closed else { return }; closed = true
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil; sealed = nil
    }
    private func timedReceive(_ socket: URLSessionWebSocketTask, milliseconds: Int) async throws -> URLSessionWebSocketTask.Message {
        let deadline = Task { try? await Task.sleep(for: .milliseconds(milliseconds)); guard !Task.isCancelled else { return }; socket.cancel(with: .goingAway, reason: nil) }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler { try await socket.receive() } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}

/// Peer frames are checked against the complete server tag/required-field map;
/// session rows and capability strings are separately narrowed before use.
public enum BackendRemoteGuestFrames {
    public static func parse(_ text: String) throws -> NativeRPCValue {
        guard text.utf8.count <= 93528 else { throw NativeRPCError.malformed("The host frame is too large") }
        let value = RNMHootWireCompatibility.incomingServerEnvelope(try NativeRPCValue.parseJSON(Data(text.utf8)))
        guard let fields = value.fields, let tag = value["t"].string, let kind = BackendRemoteServerMessage.Kind(rawValue: tag) else { throw NativeRPCError.malformed("Unknown host frame type") }
        _ = try BackendRemoteServerMessage(kind, fields: fields.filter { $0.key != "t" })
        var result = value
        // These packets are byte-for-byte symmetric in both directions. Reuse
        // their strict field/ID/base64 validators rather than widening them.
        if ["window.holds", "window.call", "window.result", "net.data", "net.ack", "net.close"].contains(tag) {
            guard case .message(let checked) = BackendRemoteProtocol.parseClientMessage(value) else { throw NativeRPCError.malformed("The host sent a malformed \(tag) frame") }
            result = checked.value
        }
        if ["welcome", "sessions"].contains(tag) {
            guard let rows = value["sessions"].elements else { throw NativeRPCError.malformed("The host omitted its sessions") }
            result = result.setting("sessions", .array(Array(rows.compactMap(BackendRemoteProtocol.remoteSession).prefix(128))))
        }
        if tag == "welcome" {
            guard value["protocol"].number == 1, let caps = value["capabilities"].elements,
                  caps.allSatisfy({ $0.string != nil }) else { throw NativeRPCError.malformed("The host protocol or capabilities are invalid") }
            result = result.setting("capabilities", .array(Array(caps.prefix(128))))
        }
        if tag == "created" {
            guard let session = BackendRemoteProtocol.remoteSession(value["session"]) else { throw NativeRPCError.malformed("The created-session frame has no usable session") }
            result = result.setting("session", session)
        }
        if tag == "ports" {
            var rows: [NativeRPCValue] = [], seen: Set<Int> = []
            for row in (value["ports"].elements ?? []).prefix(128) {
                guard let port = row["port"].number, port.isFinite, port.rounded() == port, (1...65535).contains(port), seen.insert(Int(port)).inserted,
                      let process = row["process"].string, let guessed = row["guessed"].bool else { continue }
                rows.append(.object([.init("port", .number(port)), .init("process", .string(BackendRemoteProtocol.displayLabel(process, maximumUnits: 80))), .init("guessed", .bool(guessed))]))
            }
            result = result.setting("ports", .array(rows))
        }
        if ["upload.ready", "upload.ack", "upload.done", "upload.failed", "tunnel.opened", "tunnel.closed"].contains(tag) {
            guard let id = value["id"].string, id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil else { throw NativeRPCError.malformed("The host sent an invalid transfer/tunnel id") }
        }
        if tag == "upload.done" {
            guard let hash = value["sha256"].string, hash.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
                  let count = value["bytes"].number, count.isFinite, count.rounded() == count, (1...536870912).contains(count) else { throw NativeRPCError.malformed("The upload receipt has an invalid size or checksum") }
        }
        if tag == "browser.frame" {
            guard let bytes = value["data"].string, bytes.utf16.count <= 91480, bytes.utf16.count % 4 == 0,
                  bytes.range(of: #"^[A-Za-z0-9+/]*={0,2}$"#, options: .regularExpression) != nil else { throw NativeRPCError.malformed("The host browser frame is not bounded base64") }
        }
        return result
    }
}
