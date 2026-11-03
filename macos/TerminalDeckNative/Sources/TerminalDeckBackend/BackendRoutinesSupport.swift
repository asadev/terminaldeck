import Foundation
import TerminalDeckNativeCore

/// Shared routine-only helpers. Callers may inject the data directory; creating
/// these values does not open the live directory or start a watcher.
public enum BackendRoutinesPaths {
    public static var userData: URL {
        if let override = ProcessInfo.processInfo.environment[EngineConfiguration.dataEnvironmentKey]?.trimmingCharacters(in: .whitespaces), override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/terminaldeck", isDirectory: true)
    }
    public static func routinesDirFor(_ userData: URL) -> URL { userData.appendingPathComponent("routines", isDirectory: true) }
    public static func runtimeStateFileFor(_ userData: URL) -> URL { userData.appendingPathComponent("routine-state.json") }
    public static func copilotDirFor(_ userData: URL) -> URL { RNMHootPaths(dataRoot: userData).home }
    public static var routinesDir: URL { routinesDirFor(userData) }
    public static var copilotDir: URL { copilotDirFor(userData) }
    public static func routinesDirFor(_ userData: String) -> String { routinesDirFor(URL(fileURLWithPath: userData)).path }
    public static func runtimeStateFileFor(_ userData: String) -> String { runtimeStateFileFor(URL(fileURLWithPath: userData)).path }
}

enum BackendRoutinesValues {
    static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckCoreCatalogueRules.object(pairs) }
    static func text(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
    static func number(_ value: Double?) -> NativeRPCValue { value.map(NativeRPCValue.number) ?? .null }
    static func now() -> Double { Date().timeIntervalSince1970 * 1_000 }
    static func trim(_ text: String) -> String { BackendDeckCoreCatalogueRules.trim(text) }
    static func slice(_ text: String, _ count: Int) -> String { BackendDeckCoreCatalogueRules.prefix(text, max(0, count)) }
    static let whitespacePattern = #"[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]"#
    static func match(_ text: String, _ pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            guard let range = Range(result.range(at: index), in: text) else { return "" }; return String(text[range])
        }
    }
    static func replace(_ text: String, _ pattern: String, _ replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    static func integerText(_ value: Double) -> String {
        if value.isFinite, value.rounded() == value { return String(format: "%.0f", value) }
        return String(value)
    }
    /// JavaScript String(value), needed by the draft's two untrusted counts.
    static func jsString(_ value: NativeRPCValue) -> String { BackendDeckCoreCatalogueRules.jsString(value) }
}
