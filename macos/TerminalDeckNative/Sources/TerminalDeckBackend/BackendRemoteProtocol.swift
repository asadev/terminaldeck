import Foundation
import TerminalDeckNativeCore

public struct BackendRemoteProtocolFailure: Error, Equatable, Sendable {
    public let code: String
    public let reason: String
    public init(_ reason: String, tooLarge: Bool = false) { code = tooLarge ? "too-large" : "bad-message"; self.reason = reason }
}

public struct BackendRemoteClientMessage: Equatable, Sendable {
    public let type: String
    public let value: NativeRPCValue
    init(_ value: NativeRPCValue) { self.value = value; type = value["t"].string ?? "" }
    public subscript(_ field: String) -> NativeRPCValue { value[field] }
}

public enum BackendRemoteClientParse: Equatable, Sendable {
    case message(BackendRemoteClientMessage)
    case refused(BackendRemoteProtocolFailure)
}

/// Host-side shape validation only. Authentication, device/session grants and
/// capability implementation remain mandatory decisions in the actual server.
public enum BackendRemoteProtocol {
    public static let version = 1
    public static let capabilities = ["localhost", "create", "close", "rename", "upload", "credential", "github", "host.control",
        "devserver", "copilot", "routines", "copilot.files", "web", "controls", "usage", "send", "account", "logins", "devices",
        "settings", "windows", "hostwindows", "watch", "folders.pick", "files", "git", "panels", "browser.profiles", "browser.control",
        "device.access", "hoot.events"] + panels.map { "panels." + $0 }
    public static let closeCodes = ["normal": 1000, "goingAway": 1001, "protocolError": 1002, "unsupportedData": 1003,
        "policyViolation": 1008, "messageTooBig": 1009, "internalError": 1011, "tryAgainLater": 1013]
    public static let errorCodes: Set<String> = ["bad-message", "unauthenticated", "unauthorized", "unknown-session", "too-large", "unavailable", "version"]
    public static let pickLabelSources = ["text", "label", "aria-label", "placeholder", "title", "name", "alt", "value", "none"]
    public static let credentialOperations = ["read", "write"]
    public static let credentialDenials = ["denied", "no-account"]
    public static let devServerStatuses = ["no-dev-script", "idle", "starting", "ready", "failed"]
    public static let serverSettings = ["agents.defaultProvider", "general.restoreSessions"]
    public static let controlIDs = ["model", "effort", "fast", "permission"]
    public static let usageWants = ["plan", "refresh", "context"]
    public static let panels = ["artifacts", "store", "readiness", "mcp", "tasks", "goals", "memory", "plugins", "staysfixed",
        "settings", "ai-apps", "simulators", "github", "hooks", "servers"]
    /// Recognition is not implementation. Default advertisement is empty.
    public static func advertisedCapabilities(implemented: Set<String> = []) -> [String] { capabilities.filter { implemented.contains($0) } }

    public static let limits: [String: Int] = [
        "MAX_PICK_UP": 64, "MAX_NET_CHUNK_BYTES": 24576, "MAX_NET_DATA_CHARS": 32768, "NET_WINDOW_BYTES": 262144,
        "MAX_UPLOAD_CHUNK_BYTES": 24576, "MAX_UPLOAD_DATA_CHARS": 32768, "UPLOAD_WINDOW_BYTES": 262144,
        "MAX_UPLOAD_BYTES": 536870912, "MAX_UPLOAD_NAME_BYTES": 255, "MAX_UPLOAD_DIR_BYTES": 4096, "SHA256_HEX_LENGTH": 64,
        "MAX_MESSAGE_BYTES": 65536, "MAX_TOOL_NAME_LENGTH": 64, "MAX_WINDOW_ARGS_BYTES": 16384, "MAX_WINDOW_RESULT_BYTES": 49152,
        "MAX_WINDOW_HOLDS": 128, "MAX_ANNOUNCED_SESSIONS": 128, "MAX_WATCH_WINDOWS": 8, "MIN_WATCH_WIDTH": 160,
        "MAX_WATCH_WIDTH": 1600, "MIN_WATCH_QUALITY": 1, "MAX_WATCH_QUALITY": 80, "MAX_TOUCH_POINTS": 10,
        "MIN_PAGE_WIDTH": 240, "MAX_PAGE_WIDTH": 4096, "MIN_PAGE_HEIGHT": 160, "MAX_PAGE_HEIGHT": 4096,
        "MAX_SURFACES_REPORTED": 64, "MAX_SURFACE_TITLE_LENGTH": 512, "MAX_SESSION_TITLE": 80, "MAX_WATCH_PROMPT_LENGTH": 256,
        "MAX_FRAME_BYTES": 68608, "MAX_FRAME_DATA_CHARS": 91480, "MAX_FRAME_MESSAGE_BYTES": 93528,
        "MAX_INPUT_BYTES": 16384, "OUTPUT_CHUNK_BYTES": 32768, "MAX_CWD_BYTES": 1024, "MAX_PROVIDER_LENGTH": 32,
        "MAX_URL_LENGTH": 2048, "MIN_COLS": 20, "MAX_COLS": 500, "MIN_ROWS": 5, "MAX_ROWS": 200,
        "MAX_TOKEN_LENGTH": 200, "MAX_CLIENT_CAPABILITIES": 24, "MAX_CAPABILITY_LENGTH": 32, "MAX_HOST_NAME_LENGTH": 64,
        "MAX_APP_VERSION_LENGTH": 32, "MAX_CREDENTIAL_USERNAME_LENGTH": 128, "MAX_CREDENTIAL_SECRET_LENGTH": 4096,
        "MAX_ENROLL_USERNAME_LENGTH": 64, "MAX_ENROLL_SECRET_BYTES": 16384, "MAX_ENROLL_CREDENTIAL_LENGTH": 512,
        "MAX_CREDENTIAL_HOST_LENGTH": 253, "MAX_CREDENTIAL_REPO_LENGTH": 256, "MAX_COPILOT_SAY_BYTES": 16384,
        "MAX_COPILOT_LOG_ROWS": 200, "MAX_COPILOT_MESSAGE_CHARS": 8192, "MAX_CHAT_ROWS": 200,
        "MAX_COPILOT_MEMORY_NAME": 255, "MAX_COPILOT_FILE_BYTES": 32768, "MAX_COPILOT_FILE_ROWS": 200,
        "MAX_COPILOT_FILE_PURPOSE": 240, "MAX_ROUTINES_REPORTED": 100, "MAX_ROUTINE_LINE_LENGTH": 200,
        "MAX_ROUTINE_REASON_LENGTH": 400, "MAX_ROUTINE_PROBLEMS": 8, "MAX_ROUTINE_PAUSE_REASON": 300,
        "MAX_ROUTINE_TEXT_CHARS": 12288, "MAX_SERVER_SETTING_VALUE_LENGTH": 64, "MAX_SERVER_SETTING_OPTIONS": 64,
        "MAX_CONTROL_VALUE_LENGTH": 64, "MAX_ACCOUNTS_REPORTED": 64, "MAX_CONNECTORS_REPORTED": 64,
        "MAX_ACCOUNT_NAME_LENGTH": 120, "MAX_ACCOUNT_ID_LENGTH": 200, "MAX_HOST_ADDRESS_LENGTH": 400,
        "MAX_HOST_NOTE_LENGTH": 300, "MAX_HOST_URL_LENGTH": 512, "MAX_SIGNIN_DETAIL_LENGTH": 400,
        "MAX_FILE_WINDOW": 262144, "MAX_FILE_OFFSET": 1073741824, "MAX_PANEL_WORD": 128, "MAX_PANEL_VALUE": 2048,
        "MAX_PANEL_FIELDS": 24, "MAX_KEY_FIELD_LENGTH": 64, "MAX_HELD_WINDOWS": 16, "MAX_HELD_LABEL_CHARS": 512, "MAX_HELD_SLOT": 9999,
    ]

    public static func parseClientMessage(_ raw: String) -> BackendRemoteClientParse {
        guard raw.utf8.count <= 65536 else { return .refused(.init("frame over the message limit", tooLarge: true)) }
        guard let data = raw.data(using: .utf8), let parsed = try? NativeRPCValue.parseJSON(data) else { return .refused(.init("not JSON")) }
        return parseClientMessage(parsed)
    }
    public static func parseTextFrame(_ data: Data) -> BackendRemoteClientParse {
        guard let text = String(data: data, encoding: .utf8) else { return .refused(.init("not JSON")) }
        return parseClientMessage(text)
    }
    public static func parseBinaryFrame(_ data: Data) -> BackendRemoteClientParse { .refused(.init("binary frame")) }
    public static func parseClientMessage(_ raw: NativeRPCValue) -> BackendRemoteClientParse {
        if case .bytes = raw { return .refused(.init("binary frame")) }
        guard raw.fields != nil else { return .refused(.init("not an object")) }
        guard let incomingType = raw["t"].string else { return .refused(.init("unknown message type")) }
        let type = RNMHootWireCompatibility.incomingClientType(incomingType)
        let normalized = RNMHootWireCompatibility.incomingClientEnvelope(raw)
        do {
            let reader = BackendRemoteReader(normalized, type: type)
            let value: NativeRPCValue?
            if let result = try parseSession(reader) { value = result }
            else if let result = try parseFilesAndPanels(reader) { value = result }
            else if let result = try parseBrowser(reader) { value = result }
            else if let result = try parseWatchAndWindows(reader) { value = result }
            else if let result = try parseStreamsAndCopilot(reader) { value = result }
            else { value = nil }
            guard let value else { return .refused(.init("unknown message type")) }
            return .message(BackendRemoteClientMessage(value))
        } catch let failure as BackendRemoteProtocolFailure { return .refused(failure) }
        catch { return .refused(.init("unusable message")) }
    }

    public static func containsControls(_ text: String) -> Bool { text.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) } }
    public static func displayLabel(_ text: String, maximumUnits: Int, wide: Bool = true) -> String {
        let scalars = text.unicodeScalars.filter {
            let value = $0.value
            return !(value < 32 || (127...159).contains(value) || (wide && ((0x2028...0x202e).contains(value) || (0x2066...0x2069).contains(value))))
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = "", units = 0
        for scalar in cleaned.unicodeScalars {
            let next = scalar.value > 65535 ? 2 : 1
            if units + next > maximumUnits { break }
            result.unicodeScalars.append(scalar); units += next
        }
        return result
    }
}

struct BackendRemoteReader {
    let raw: NativeRPCValue
    let type: String
    init(_ raw: NativeRPCValue, type: String) { self.raw = raw; self.type = type }
    subscript(_ key: String) -> NativeRPCValue { raw[key] }
    var base: NativeRPCValue { .object([.init("t", .string(type))]) }
    func bad(_ reason: String) -> BackendRemoteProtocolFailure { .init(reason) }
    func large(_ reason: String) -> BackendRemoteProtocolFailure { .init(reason, tooLarge: true) }
    func text(_ key: String, reason: String, allowEmpty: Bool = false, bytes: Int? = nil, units: Int? = nil,
              controls: Bool = false, oversize: String? = nil, controlReason: String? = nil) throws -> String {
        guard let value = self[key].string, allowEmpty || !value.isEmpty else { throw bad(reason) }
        if let bytes, value.utf8.count > bytes { throw oversize.map(large) ?? bad(reason) }
        if let units, value.utf16.count > units { throw oversize.map(large) ?? bad(reason) }
        guard !controls || !BackendRemoteProtocol.containsControls(value) else { throw bad(controlReason ?? reason) }
        return value
    }
    func id(_ key: String, reason: String, device: Bool = false, watch: Bool = false) throws -> String {
        let value = try text(key, reason: reason)
        let pattern = device ? #"^[A-Za-z0-9_-]{1,64}$"# : watch ? #"^[A-Za-z0-9][A-Za-z0-9_:-]{0,63}$"# : #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { throw bad(reason) }
        return value
    }
    func whole(_ key: String, _ minimum: Double, _ maximum: Double, reason: String) throws -> Double {
        guard let value = self[key].number, value.rounded() == value, value >= minimum, value <= maximum else { throw bad(reason) }
        return value
    }
    func finite(_ key: String, reason: String) throws -> Double { guard let value = self[key].number else { throw bad(reason) }; return value }
    func boolean(_ key: String, reason: String) throws -> Bool { guard let value = self[key].bool else { throw bad(reason) }; return value }
    func named(_ key: String, allowed: [String], reason: String) throws -> String {
        let value = try text(key, reason: reason)
        guard allowed.contains(value) else { throw bad(reason) }
        return value
    }
    func folder(_ key: String, unusable: String, oversized: String) throws -> String {
        try text(key, reason: unusable, bytes: 1024, controls: true, oversize: oversized)
    }
    func optional(_ key: String, into result: inout NativeRPCValue, _ read: () throws -> NativeRPCValue) throws {
        if self[key] != .missing { result = result.setting(key, try read()) }
    }
}
