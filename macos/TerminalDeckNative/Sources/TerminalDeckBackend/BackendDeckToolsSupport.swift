import Foundation
import TerminalDeckNativeCore

/// Tool metadata the MCP value does not yet carry. The central deck gate owns
/// schema validation, consent, budget, aliases and unconditional action logging.
/// Area handlers still own their source-specific narrowing and refusal rules.
public struct BackendDeckToolsDefinition: Sendable {
    public let spec: BackendMCPTool
    public let title: String
    public let index: String?
    public let aliases: [String]
    public let audience: String?
    public let keyIndex: String?
    public let keyGrant: String?
    public let handler: BackendNativeMCPServer.Handler
    public init(spec: BackendMCPTool, title: String, index: String? = nil,
                aliases: [String] = [], audience: String? = nil, keyIndex: String? = nil, keyGrant: String? = nil,
                handler: @escaping BackendNativeMCPServer.Handler) {
        self.spec = spec; self.title = title; self.index = index
        self.aliases = aliases; self.audience = audience; self.keyIndex = keyIndex
        self.keyGrant = keyGrant; self.handler = handler
    }
    /// Feed this alongside the area to the central catalogue/describe gate.
    public var metadata: NativeRPCValue {
        BackendDeckToolsSupport.object([("id", .string(spec.id)), ("wire", .string(spec.wireName)),
            ("title", .string(title)), ("index", index.map(NativeRPCValue.string) ?? .missing),
            ("aliases", .array(aliases.map(NativeRPCValue.string))),
            ("audience", audience.map(NativeRPCValue.string) ?? .missing),
            ("keyIndex", keyIndex.map(NativeRPCValue.string) ?? .missing),
            ("keyGrant", keyGrant.map(NativeRPCValue.string) ?? .missing)])
    }
    public var catalogueMetadata: BackendDeckCoreCatalogueMetadata {
        .init(tool: spec, title: title, aliases: aliases, index: index,
              audience: audience, keyIndex: keyIndex, keyGrant: keyGrant)
    }
}

public enum BackendDeckToolsSupport {
    public static func area(id: String, definitions: [BackendDeckToolsDefinition]) throws -> BackendDeckCoreToolArea {
        guard Set(definitions.map { $0.spec.id }).count == definitions.count else {
            throw BackendSessionFailure.invalidInput("A tool area contains duplicate tool ids.")
        }
        return try BackendDeckCoreToolArea(id: id, tools: definitions.map(\.spec),
            describeText: definitions.map { "\($0.spec.id): \($0.index ?? $0.spec.description)" }.joined(separator: "\n"),
            handlers: Dictionary(uniqueKeysWithValues: definitions.map { ($0.spec.id, $0.handler) }))
    }
    public static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue {
        .object(pairs.map { .init($0.0, $0.1) })
    }
    public static func unavailable(_ operation: String) -> NativeRPCError {
        .init(code: "unavailable", message: "\(operation) is unavailable: its native service has not been supplied.")
    }
    /// BackendNativeMCPServer intentionally hides arbitrary thrown errors.
    /// Convert known source refusals here so their exact sentences survive.
    /// The central gate still records refused/error rows, including prechecks.
    public static func reply(_ operation: @escaping @Sendable () async throws -> BackendMCPToolReply) async -> BackendMCPToolReply {
        do { return try await operation() }
        catch is CancellationError { return .failure("The caller went away.") }
        catch let refusal as BackendDeckCoreSecurityRefusal {
            return BackendMCPToolReply(content: [.object([.init("type", .string("text")), .init("text", .string(refusal.message))])],
                structuredContent: object([("ok", .bool(false)), ("error", .string(refusal.message)), ("refusal", .string(refusal.reason.rawValue))]), isError: true)
        }
        catch {
            let failure = NativeRPCError.wrapping(error)
            let refusal: NativeRPCValue = failure.code.hasPrefix("not-") ? .string(failure.code) : .null
            return BackendMCPToolReply(content: [.object([.init("type", .string("text")), .init("text", .string(failure.message))])],
                structuredContent: object([("ok", .bool(false)), ("error", .string(failure.message)), ("refusal", refusal), ("code", .string(failure.code))]), isError: true)
        }
    }
    /// JavaScript string.length/slice are UTF-16, including astral characters.
    public static func length(_ value: String) -> Int { value.utf16.count }
    public static func slice(_ value: String, _ start: Int = 0, _ end: Int? = nil) -> String {
        let units = Array(value.utf16), low = max(0, min(start, units.count))
        let high = max(low, min(end ?? units.count, units.count))
        return String(decoding: units[low..<high], as: UTF16.self)
    }
}

/// catalogue.ts / area-shared.ts argument helpers, including their sentences.
/// optInt clamps/truncates; int is the stricter whole-number helper.
public enum BackendDeckToolsArgs {
    public static func bad(_ message: String) -> NativeRPCError { .init(code: "bad-argument", message: message) }
    public static func str(_ args: NativeRPCValue, _ key: String) throws -> String {
        guard let value = args[key].string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw bad("\(key) is required and must be a non-empty string")
        }
        return value
    }
    public static func optStr(_ args: NativeRPCValue, _ key: String) throws -> String? {
        let value = args[key]
        if value.isNullish || value.string == "" { return nil }
        guard let text = value.string else { throw bad("\(key) must be a string") }
        return text
    }
    public static func optBool(_ args: NativeRPCValue, _ key: String, _ fallback: Bool) throws -> Bool {
        if args[key].isNullish { return fallback }
        guard let value = args[key].bool else { throw bad("\(key) must be true or false") }
        return value
    }
    public static func bool(_ args: NativeRPCValue, _ key: String) throws -> Bool {
        guard let value = args[key].bool else { throw bad("\(key) is required and must be true or false") }
        return value
    }
    public static func optInt(_ args: NativeRPCValue, _ key: String, _ fallback: Int, _ min: Int, _ max: Int) throws -> Int {
        if args[key].isNullish { return fallback }
        guard let number = args[key].number else { throw bad("\(key) must be a number") }
        return Int(Swift.min(Swift.max(number.rounded(.towardZero), Double(min)), Double(max)))
    }
    public static func int(_ args: NativeRPCValue, _ key: String, _ min: Int, _ max: Int) throws -> Int {
        guard let number = args[key].number, number.rounded(.towardZero) == number else {
            throw bad("\(key) is required and must be a whole number")
        }
        guard number >= Double(min), number <= Double(max) else { throw bad("\(key) must be between \(min) and \(max)") }
        return Int(number)
    }
    public static func oneOf(_ args: NativeRPCValue, _ key: String, _ allowed: [String]) throws -> String {
        let value = try str(args, key)
        guard allowed.contains(value) else { throw bad("\(key) must be one of: \(allowed.joined(separator: ", "))") }
        return value
    }
    public static func record(_ args: NativeRPCValue, _ key: String) throws -> NativeRPCValue {
        guard args[key].fields != nil else { throw bad("\(key) must be an object") }
        return args[key]
    }
    public static func strList(_ args: NativeRPCValue, _ key: String) throws -> [String] {
        guard let values = args[key].elements, values.allSatisfy({ $0.string != nil }) else {
            throw bad("\(key) is required and must be a list of strings")
        }
        return values.compactMap(\.string)
    }
}
