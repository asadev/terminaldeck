import Foundation
import TerminalDeckNativeCore

/// Server-control output uses the existing shared redactor, with complete env
/// masking even for innocently named values, and no opaque terminal bytes.
public enum BackendDockerMCPMasker {
    public static let masked = BackendSharedRedact.redacted

    public static func text(_ input: String, extraSecrets: [String] = []) -> String {
        var result = input
        // The general redactor skips short literals. An explicitly supplied
        // server secret is still secret when it happens to be short.
        for secret in Set(extraSecrets).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: masked)
        }
        return BackendSharedRedact.redact(result, options: .init(home: "", username: "", keepIdentity: true))
    }

    public static func arguments(_ value: NativeRPCValue) -> NativeRPCValue { self.value(value) }

    public static func value(_ value: NativeRPCValue, extraSecrets: [String] = []) -> NativeRPCValue {
        let secrets = extraSecrets + environmentValues(value)
        return walk(value, extraSecrets: secrets)
    }

    public static func secrets(in value: NativeRPCValue) -> [String] { environmentValues(value) }

    private static func environmentValues(_ value: NativeRPCValue) -> [String] {
        if let array = value.elements { return array.flatMap(environmentValues) }
        guard let fields = value.fields else { return [] }
        if isEnvironmentRow(value), let rowValue = value["value"].string { return [rowValue] }
        return fields.flatMap { field -> [String] in
            if isPublicConnectionField(field, in: value) { return [] }
            if isEnvironment(field.key) || field.key == "set" && isEnvironmentPatch(value) { return envValues(field.value) }
            if BackendSharedRedact.isSecretKey(field.key), let secret = field.value.string { return [secret] }
            return environmentValues(field.value)
        }
    }
    private static func envValues(_ value: NativeRPCValue) -> [String] {
        if let fields = value.fields {
            if let rowValue = value["value"].string, isEnvironmentRow(value) { return [rowValue] }
            return fields.flatMap { envValues($0.value) }
        }
        if let values = value.elements { return values.flatMap(envValues) }
        if let string = value.string {
            if let equal = string.firstIndex(of: "=") { return [String(string[string.index(after: equal)...])] }
            return [string]
        }
        return []
    }
    private static func isEnvironment(_ key: String) -> Bool {
        ["env", "environment", "environmentvariables", "environmentvalues"].contains(key.lowercased())
    }
    private static func isEnvironmentRow(_ value: NativeRPCValue) -> Bool {
        value.has("value") && (value["name"].string != nil || value["key"].string != nil || value["secret"].bool == true)
    }
    private static func isEnvironmentPatch(_ value: NativeRPCValue) -> Bool {
        value["set"].fields != nil && value["appId"].string != nil && value["serverId"].string != nil
    }
    private static func isPublicConnectionField(_ field: NativeRPCValue.Field, in value: NativeRPCValue) -> Bool {
        guard value["scope"].string == "private-network", let kind = value["kind"].string,
              let passwordKey = ["postgres": "POSTGRES_PASSWORD", "mysql": "MYSQL_ROOT_PASSWORD", "redis": "REDIS_PASSWORD", "mongodb": "MONGO_INITDB_ROOT_PASSWORD"][kind] else { return false }
        if field.key == "passwordKey" { return field.value.string == passwordKey }
        if field.key == "authenticationDatabase" { return kind == "mongodb" ? field.value.string == "admin" : field.value == .null }
        return false
    }
    private static func maskEnvironment(_ value: NativeRPCValue, extraSecrets: [String] = []) -> NativeRPCValue {
        if let values = value.elements { return .array(values.map { maskEnvironment($0, extraSecrets: extraSecrets) }) }
        if let fields = value.fields {
            if isEnvironmentRow(value) {
                return .object(fields.map { .init($0.key, $0.key == "value" ? .string(masked) : walk($0.value, extraSecrets: extraSecrets)) })
            }
            return .object(fields.map { .init($0.key, .string(masked)) })
        }
        if let string = value.string, let equal = string.firstIndex(of: "=") {
            return .string(String(string[...equal]) + masked)
        }
        return .string(masked)
    }
    private static func walk(_ value: NativeRPCValue, extraSecrets: [String]) -> NativeRPCValue {
        switch value {
        case .string(let string): return .string(text(string, extraSecrets: extraSecrets))
        case .array(let values): return .array(values.map { walk($0, extraSecrets: extraSecrets) })
        case .object(let fields):
            if isEnvironmentRow(value) { return maskEnvironment(value, extraSecrets: extraSecrets) }
            return .object(fields.map { field in
                let key = field.key.lowercased()
                if isPublicConnectionField(field, in: value) { return field }
                if isEnvironment(field.key) || field.key == "set" && isEnvironmentPatch(value) { return .init(field.key, maskEnvironment(field.value, extraSecrets: extraSecrets)) }
                if key == "command", field.value.string == BackendDockerInstall.command { return field }
                if BackendSharedRedact.isSecretKey(field.key) || ["command", "cmd", "entrypoint", "data", "contentbase64", "rawinspect"].contains(key) {
                    return .init(field.key, .string(masked))
                }
                return .init(field.key, walk(field.value, extraSecrets: extraSecrets))
            })
        case .bytes: return .string(masked)
        default: return value
        }
    }
}
