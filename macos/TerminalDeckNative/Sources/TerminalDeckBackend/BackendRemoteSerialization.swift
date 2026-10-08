import Foundation
import TerminalDeckNativeCore

/// Server tags are closed like ServerMessage in protocol.ts. Payload fields stay
/// ordered and additive; host domain code constructs their actual readings.
public struct BackendRemoteServerMessage: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case welcome, enrolled, sessions, attached, detached, output, status, exit, error, pong, created, closed, folders, ports
        case folderEntries = "folders.entries", fileRows = "files.rows", fileText = "files.text", gitState = "git.state", gitPatch = "git.patch"
        case browserProfileRows = "browser.profile.rows", panelRows = "panel.rows", routineRows = "routines.rows", routineTextRows = "routine.text.rows"
        case browserWindowRows = "browser.window.rows", browserShot = "browser.shot", browserRecordRows = "browser.record.rows", browserWindowPicked = "browser.window.picked"
        case tunnelOpened = "tunnel.opened", tunnelClosed = "tunnel.closed", netData = "net.data", netAck = "net.ack", netClose = "net.close"
        case webOpened = "web.opened", devState = "dev.state", uploadReady = "upload.ready", uploadAck = "upload.ack", uploadDone = "upload.done", uploadFailed = "upload.failed"
        case credentialRequest = "credential.request", copilotState = "copilot.state", copilotChat = "copilot.chat", copilotTool = "copilot.tool"
        case copilotSessions = "copilot.sessions", copilotLog = "copilot.log", copilotPending = "copilot.pending", copilotGrant = "copilot.grant"
        case copilotAsk = "copilot.ask", copilotSettled = "copilot.settled", copilotFileRows = "copilot.files.rows", copilotFileText = "copilot.file.text"
        case controlsReading = "controls.reading", controlsApplied = "controls.applied", usageReading = "usage.reading", accountState = "account.state", accountSwitched = "account.switched"
        case loginState = "logins.state", loginSignedIn = "logins.signedin", loginSignedOut = "logins.signedout", settingsState = "settings.state", settingsApplied = "settings.applied", settingsChanged = "settings.changed"
        case githubState = "github.state", githubChanged = "github.changed", hostState = "host.state", sessionSent = "session.sent"
        case deviceRows = "devices.rows", deviceRevoked = "devices.revoked", devicesChanged = "devices.changed"
        case deviceAccess = "device.access", hootEvents = "hoot.events"
        case windowCall = "window.call", windowHolds = "window.holds", windowResult = "window.result"
        case browserFrame = "browser.frame", browserSurfaceRows = "browser.surfaces.rows", browserHandoverState = "browser.handover.state"
    }
    public let kind: Kind
    public let value: NativeRPCValue
    public init(_ kind: Kind, fields: [NativeRPCValue.Field]) throws {
        guard !fields.contains(where: { $0.key == "t" }) else { throw NativeRPCError.invalidArguments("Server fields cannot replace the frame tag") }
        self.kind = kind
        value = .object([.init("t", .string(kind.rawValue))] + fields)
        try Self.validateRequiredFields(kind, value: value)
    }
    public static func error(code: String, message: String) throws -> Self {
        guard BackendRemoteProtocol.errorCodes.contains(code) else { throw NativeRPCError.invalidArguments("Unknown remote protocol error code") }
        return try Self(.error, fields: [.init("code", .string(code)), .init("message", .string(message))])
    }
    /// Required top-level fields come from the complete ServerMessage union.
    /// Additive/optional readings remain intact rather than being reprojected.
    private static let requiredFieldSchemas: [Kind: String] = [
            .welcome: "protocol:n deviceId:s deviceName:s token:s? sessions:a capabilities:a", .enrolled: "deviceId:s deviceName:s credential:s",
            .sessions: "sessions:a", .attached: "id:s", .detached: "id:s", .output: "id:s data:s", .status: "id:s status:s", .exit: "id:s exitCode:n",
            .error: "code:s message:s", .pong: "", .created: "session:o", .closed: "id:s", .folders: "folders:a",
            .folderEntries: "path:s parent:s? entries:a", .fileRows: "path:s parent:s? entries:a", .fileText: "path:s text:s at:n truncated:b binary:b",
            .gitState: "path:s status:u", .gitPatch: "path:s file:s staged:b patch:s", .browserProfileRows: "current:s profiles:a",
            .panelRows: "panel:s path:s rows:a", .routineRows: "routines:a", .routineTextRows: "id:s file:s text:s readOnlyBecause:s",
            .browserWindowRows: "windows:a sessions:a", .browserShot: "id:s png:s at:n", .browserRecordRows: "id:s steps:a",
            .browserWindowPicked: "id:s tag:s selector:s label:s labelSource:s url:s rect:o depth:n maxUp:n", .ports: "ports:a",
            .tunnelOpened: "id:s port:n", .tunnelClosed: "id:s message:s", .netData: "ch:s data:s", .netAck: "ch:s bytes:n", .netClose: "ch:s",
            .webOpened: "url:s", .devState: "state:o", .uploadReady: "id:s path:s", .uploadAck: "id:s bytes:n",
            .uploadDone: "id:s path:s bytes:n sha256:s", .uploadFailed: "id:s message:s", .credentialRequest: "id:s host:s repo:s? operation:s prompt:b",
            .windowCall: "id:s session:s tool:s args:s", .windowHolds: "sessions:a", .windowResult: "id:s ok:b body:s",
            .browserFrame: "window:s seq:n w:n h:n dw:n dh:n scale:n offsetTop:n pageScale:n scrollX:n scrollY:n data:s",
            .browserSurfaceRows: "surfaces:a", .browserHandoverState: "window:s asking:b prompt:s mine:b taken:b",
            .copilotState: "state:o", .copilotChat: "run:s messages:a", .copilotTool: "row:o", .copilotSessions: "sessions:a",
            .copilotLog: "rows:a more:b", .copilotPending: "questions:a", .copilotGrant: "link:o", .copilotAsk: "question:o", .copilotSettled: "settled:o",
            .copilotFileRows: "files:a", .copilotFileText: "id:s text:s", .controlsReading: "rid:s id:s reading:o",
            .controlsApplied: "rid:s id:s ok:b message:s reading:o", .usageReading: "rid:s id:s want:s answer:o",
            .accountState: "rid:s id:s current:o? accounts:a", .accountSwitched: "rid:s id:s ok:b message:s session:s?",
            .loginState: "rid:s accounts:a", .loginSignedIn: "rid:s ok:b message:s session:s?", .loginSignedOut: "rid:s ok:b message:s session:s?",
            .settingsState: "rid:s settings:a", .settingsApplied: "rid:s ok:b message:s setting:o", .settingsChanged: "settings:a",
            .githubState: "rid:s github:o", .githubChanged: "github:o", .hostState: "rid:s host:o", .sessionSent: "rid:s id:s ok:b message:s",
            .deviceRows: "rid:s devices:a", .deviceRevoked: "rid:s ok:b message:s devices:a", .devicesChanged: "devices:a",
            .deviceAccess: "level:s?", .hootEvents: "conversationId:s reset:b events:a",
    ]
    private static func validateRequiredFields(_ kind: Kind, value: NativeRPCValue) throws {
        if kind == .deviceAccess {
            guard value["level"] == .null || value["level"].string.flatMap(BackendINT2PhoneAccessLevel.init(rawValue:)) != nil else {
                throw NativeRPCError.malformed("The host device access level is invalid.")
            }
        }
        if kind == .hootEvents {
            let events = try value["events"].requireArray("Hoot events")
            guard events.count <= 600, let conversation = value["conversationId"].string, !conversation.isEmpty else {
                throw NativeRPCError.malformed("The Hoot event snapshot is not bounded.")
            }
            for event in events {
                let decoded = try HootChatEvent(wire: event)
                guard decoded.conversationID == conversation,
                      (event["value"]["text"].string?.utf8.count ?? 0) <= 65536,
                      ((try? event["value"]["input"].encodedJSON().count) ?? 0) <= 16384 else {
                    throw NativeRPCError.malformed("The Hoot event exceeds the phone contract.")
                }
            }
        }
        guard let spec = requiredFieldSchemas[kind] else { throw NativeRPCError.invalidArguments("No server schema for \(kind.rawValue)") }
        for item in spec.split(separator: " ") {
            let pair = item.split(separator: ":", maxSplits: 1), key = String(pair[0]), rule = String(pair[1])
            let field = value[key]
            let nullable = rule.hasSuffix("?")
            let valid: Bool
            if nullable && field == .null { valid = true }
            else {
                switch rule.first {
                case "s": valid = field.string != nil
                case "n": valid = field.number != nil
                case "b": valid = field.bool != nil
                case "a": valid = field.elements != nil
                case "o": valid = field.fields != nil
                default: valid = field != .missing
                }
            }
            guard valid else { throw NativeRPCError.invalidArguments("\(kind.rawValue) has a malformed required field: \(key)") }
        }
        if kind == .error, !BackendRemoteProtocol.errorCodes.contains(value["code"].string ?? "") {
            throw NativeRPCError.invalidArguments("Unknown remote protocol error code")
        }
        if kind == .credentialRequest, !BackendRemoteProtocol.credentialOperations.contains(value["operation"].string ?? "") {
            throw NativeRPCError.invalidArguments("Unknown credential operation")
        }
    }
}

public extension BackendRemoteProtocol {
    static func serialize(_ message: BackendRemoteServerMessage) throws -> String { try BackendRemoteJSON.write(message.value) }
    static func serialize(_ message: BackendRemoteClientMessage) throws -> String { try BackendRemoteJSON.write(message.value) }
    static func serializedBytes(_ message: BackendRemoteServerMessage) throws -> Data { Data(try serialize(message).utf8) }

    /// JSON.stringify string-content budget, without splitting a code point.
    static func chunkOutput(_ data: String, size: Int = 32768) -> [String] { chunks(data, rawBudget: nil, jsonBudget: size) }
    /// Both UTF-8 paste size and escaped frame size matter. Backslashes/control
    /// text can hit the JSON budget well before the terminal's raw-byte budget.
    static func chunkInput(_ data: String, size: Int = 16384) -> [String] { chunks(data, rawBudget: size, jsonBudget: 32768) }
    private static func chunks(_ data: String, rawBudget: Int?, jsonBudget: Int) -> [String] {
        if data.isEmpty { return [] }
        var output: [String] = [], current = "", raw = 0, json = 0
        for scalar in data.unicodeScalars {
            let code = scalar.value
            let rawCost = code < 128 ? 1 : code < 2048 ? 2 : code < 65536 ? 3 : 4
            let jsonCost: Int
            if code < 32 { jsonCost = [8, 9, 10, 12, 13].contains(code) ? 2 : 6 }
            else if code == 34 || code == 92 { jsonCost = 2 }
            else { jsonCost = rawCost }
            if !current.isEmpty && (json + jsonCost > jsonBudget || rawBudget.map({ raw + rawCost > $0 }) == true) {
                output.append(current); current = ""; raw = 0; json = 0
            }
            current.unicodeScalars.append(scalar); raw += rawCost; json += jsonCost
        }
        if !current.isEmpty { output.append(current) }
        return output
    }
}

/// JSON.stringify ordering and number spelling, including its decimal range
/// [1e-6,1e21). OrderedJSON.quote supplies the same string escaping.
enum BackendRemoteJSON {
    static func write(_ value: NativeRPCValue, depth: Int = 0) throws -> String {
        guard depth <= 64 else { throw NativeRPCError.malformed("Remote message nesting exceeds 64 levels") }
        switch value {
        case .missing, .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return number(value)
        case .string(let value): return OrderedJSON.quote(value)
        case .bytes: throw NativeRPCError.invalidArguments("Remote message bytes must be explicit base64 text")
        case .array(let values): return "[" + (try values.map { try write($0, depth: depth + 1) }).joined(separator: ",") + "]"
        case .object(let fields):
            var value = NativeRPCValue.object([])
            for field in fields { value = value.setting(field.key, field.value) }
            let known = (value.fields ?? []).filter { $0.value != .missing }
            let ordered = known.enumerated().sorted { a, b in
                func index(_ key: String) -> UInt32? {
                    guard let number = UInt32(key), number < UInt32.max, String(number) == key else { return nil }
                    return number
                }
                switch (index(a.element.key), index(b.element.key)) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
            return "{" + (try ordered.map { OrderedJSON.quote($0.key) + ":" + (try write($0.value, depth: depth + 1)) }).joined(separator: ",") + "}"
        }
    }
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == 0 { return "0" }
        var text = String(value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        guard let marker = text.firstIndex(of: "e"), let exponent = Int(text[text.index(after: marker)...]) else { return text }
        let mantissa = String(text[..<marker])
        if abs(value) >= 0.000001 && abs(value) < 1e21 {
            let negative = mantissa.hasPrefix("-")
            let unsigned = negative ? String(mantissa.dropFirst()) : mantissa
            let pieces = unsigned.split(separator: ".", omittingEmptySubsequences: false)
            let digits = pieces.joined()
            let place = (pieces.first?.count ?? 0) + exponent
            let result: String
            if place <= 0 { result = "0." + String(repeating: "0", count: -place) + digits }
            else if place >= digits.count { result = digits + String(repeating: "0", count: place - digits.count) }
            else { let split = digits.index(digits.startIndex, offsetBy: place); result = String(digits[..<split]) + "." + String(digits[split...]) }
            return (negative ? "-" : "") + result
        }
        return mantissa + "e" + (exponent >= 0 ? "+" : "-") + String(abs(exponent))
    }
}
