import Foundation
import TerminalDeckNativeCore

public struct BackendSharedServerAddress: Equatable, Sendable {
    public let url: String
    public let hostId: String
    public let hostKey: String
    public init(url: String, hostId: String, hostKey: String) { self.url = url; self.hostId = hostId; self.hostKey = hostKey }
    /// Fixed JSON field order is part of the token format.
    public var wireValue: NativeRPCValue { .object([.init("kind", .string("relay")), .init("url", .string(url)), .init("hostId", .string(hostId)), .init("hostKey", .string(hostKey))]) }
}

/// shared/server-address.ts and pairing-link.ts. The address carries public
/// material only; this parser grants no access and performs no connection.
public enum BackendSharedServerAddresses {
    public static let version = 1
    public static let prefix = "srv1."
    public static let addressIsNotASecret = "This address is not a secret. It holds a public key and a public name at a relay, and it grants nothing on its own — signing in still needs a login this server already accepts."
    public static func isHostId(_ value: String) -> Bool { BackendSharedText.matches(value, #"^[A-HJ-NP-Z2-9]{26}$"#) }
    public static func isRelayUrl(_ value: String) -> Bool {
        let folded = value.lowercased()
        return (folded.hasPrefix("ws://") || folded.hasPrefix("wss://")) && BackendSharedText.matches(value, #"(?i)^wss?://\S+$"#) && value.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value != 0x7f }
    }
    public static func toBase64Url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    /// Node Buffer's forgiving decoder. Outer tokens additionally require a
    /// canonical re-encode; host keys deliberately use the source's length check.
    public static func fromBase64Url(_ text: String) -> Data {
        let leading = text.components(separatedBy: "=").first ?? ""
        var folded = leading.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }
        if folded.count % 4 == 1 { folded.removeLast() }
        folded += String(repeating: "=", count: (4 - folded.count % 4) % 4)
        return Data(base64Encoded: folded) ?? Data()
    }
    public static func hostKeyBytes(_ key: String) -> Data? {
        guard key.utf16.count <= 128 else { return nil }
        let bytes = fromBase64Url(key)
        return bytes.count == 32 ? bytes : nil
    }
    public static func asAddress(_ value: NativeRPCValue) -> BackendSharedServerAddress? {
        guard value.fields != nil, value["kind"].string == "relay", let url = value["url"].string, isRelayUrl(url),
              let hostId = value["hostId"].string, isHostId(hostId), let hostKey = value["hostKey"].string,
              let key = hostKeyBytes(hostKey) else { return nil }
        return .init(url: url, hostId: hostId, hostKey: toBase64Url(key))
    }
    public static func format(url: String, hostId: String, hostKey: String) -> String? {
        guard let address = asAddress(BackendSharedServerAddress(url: url, hostId: hostId, hostKey: hostKey).wireValue),
              let bytes = try? address.wireValue.encodedJSON() else { return nil }
        return prefix + toBase64Url(bytes)
    }
    public static func parse(_ text: String) -> BackendSharedServerAddress? {
        let token = BackendSharedText.trim(text)
        guard !token.isEmpty, token.utf16.count <= 4096, token.hasPrefix(prefix) else { return nil }
        let body = String(token.dropFirst(prefix.count)), bytes = fromBase64Url(body)
        guard !bytes.isEmpty, toBase64Url(bytes) == body, let parsed = try? NativeRPCValue.parseJSON(bytes) else { return nil }
        return asAddress(parsed)
    }
    public static func isServerAddress(_ text: String) -> Bool { parse(text) != nil }
}

public enum BackendSharedServerWhere {
    public static let defaultSSHPort = 22
    public static func address(_ address: String, port: Double? = nil) -> String {
        guard let port, port.isFinite, port.rounded() == port, port >= 1, port <= 65535, port != Double(defaultSSHPort) else { return address }
        let host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        return "\(host):\(Int(port))"
    }
    public static func whereLine(address: String, port: Double? = nil, username: String) -> String {
        let place = Self.address(address, port: port)
        return username.isEmpty ? place : "\(username) at \(place)"
    }
}
