import Foundation
import TerminalDeckNativeCore

/// One shared tool specification for metadata and bound area handlers. The central deck gate owns
/// schema validation, consent, budget, aliases and unconditional action logging.
/// Area handlers still own their source-specific narrowing and refusal rules.
public typealias BackendDeckToolsDefinition = BackendMCPTool

public extension BackendMCPTool {
    /// Feed this alongside the area to the central catalogue/describe gate.
    var metadata: NativeRPCValue {
        BackendDeckToolsSupport.object([("id", .string(spec.id)), ("wire", .string(spec.wireName)),
            ("title", .string(title)), ("index", index.map(NativeRPCValue.string) ?? .missing),
            ("aliases", .array(aliases.map(NativeRPCValue.string))),
            ("audience", audience.map(NativeRPCValue.string) ?? .missing),
            ("keyIndex", keyIndex.map(NativeRPCValue.string) ?? .missing),
            ("keyGrant", keyGrant.map(NativeRPCValue.string) ?? .missing)])
    }
    var catalogueMetadata: BackendDeckCoreCatalogueMetadata { self }
}

public enum BackendDeckToolsSupport {
    /// Build each area once, from the same specs used for describe and registration.
    public static func areas(definitions: [BackendMCPTool]) throws -> [BackendDeckCoreToolArea] {
        let grouped = Dictionary(grouping: definitions) { BackendDeckCoreCatalogueDescribe.areaOf($0.id) }
        let order = BackendDeckCoreCatalogueDescribe.areas.map(\.id)
        let names = grouped.keys.sorted { first, second in
            let a = order.firstIndex(of: first) ?? order.count, b = order.firstIndex(of: second) ?? order.count
            return a == b ? first < second : a < b
        }
        return try names.map { try area(id: $0, definitions: grouped[$0]!) }
    }
    public static func area(id: String, definitions: [BackendDeckToolsDefinition]) throws -> BackendDeckCoreToolArea {
        guard definitions.allSatisfy(\.hasHandler), Set(definitions.map { $0.spec.id }).count == definitions.count else {
            throw BackendSessionFailure.invalidInput("A tool area needs one bound handler per unique tool id.")
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
    static func parsed<T>(_ read: () throws -> T) throws -> T {
        do { return try read() } catch let error as NativeRPCError { throw bad(error.message) }
    }
    public static func bad(_ message: String) -> NativeRPCError { .init(code: "bad-argument", message: message) }
    public static func str(_ args: NativeRPCValue, _ key: String) throws -> String { try parsed { try BackendDeckCoreArguments.str(args, key) } }
    public static func optStr(_ args: NativeRPCValue, _ key: String) throws -> String? { try parsed { try BackendDeckCoreArguments.optStr(args, key) } }
    public static func optBool(_ args: NativeRPCValue, _ key: String, _ fallback: Bool) throws -> Bool { try parsed { try BackendDeckCoreArguments.optBool(args, key, fallback: fallback) } }
    public static func bool(_ args: NativeRPCValue, _ key: String) throws -> Bool { try parsed { try BackendDeckCoreArguments.bool(args, key) } }
    public static func optInt(_ args: NativeRPCValue, _ key: String, _ fallback: Int, _ min: Int, _ max: Int) throws -> Int { try parsed { try BackendDeckCoreArguments.optionalInt(args, key, fallback: fallback, min: min, max: max) } }
    public static func int(_ args: NativeRPCValue, _ key: String, _ min: Int, _ max: Int) throws -> Int { try parsed { try BackendDeckCoreArguments.int(args, key, min: min, max: max) } }
    public static func oneOf(_ args: NativeRPCValue, _ key: String, _ allowed: [String]) throws -> String { try parsed { try BackendDeckCoreArguments.oneOf(args, key, allowed: allowed) } }
    public static func record(_ args: NativeRPCValue, _ key: String) throws -> NativeRPCValue { try parsed { try BackendDeckCoreArguments.record(args, key) } }
    public static func strList(_ args: NativeRPCValue, _ key: String) throws -> [String] { try parsed { try BackendDeckCoreArguments.strList(args, key) } }
}
