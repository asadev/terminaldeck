import Foundation
import TerminalDeckNativeCore
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Ajv 8.20.0's default unicodeRegExp:true uses new RegExp(pattern, "u")
/// and .test(data), without implicit anchors. Source:
/// https://github.com/ajv-validator/ajv/blob/v8.20.0/lib/vocabularies/code.ts
/// https://github.com/ajv-validator/ajv/blob/v8.20.0/lib/vocabularies/validation/pattern.ts
///
/// The existing browser regexp helper has source-specific 512-character and
/// input limits absent from Ajv. This helper therefore uses the same isolated
/// system JavaScriptCore facility directly, only for RegExp construction,
/// matching and captures. No JS schema validator, Node, DOM, network, filesystem
/// or native callback is installed. Input is passed as data, never as JS code.
/// Each validation owns one lazy context and compiled-pattern cache; nothing crosses threads.
///
/// Platform limit: WebKit and V8 may differ on newer regexp syntax/Unicode
/// property versions and SyntaxError wording. Unsupported syntax throws; there
/// is no ICU substitute accepting a different language. Swift String cannot
/// carry an unpaired UTF-16 surrogate: that limitation belongs to the shared
/// NativeRPCValue JSON boundary before this helper receives the value.
public enum BackendMcpClientJSONSchemaPattern {
    public static func validate(_ pattern: String) throws { try Session().validate(pattern) }
    public static func matches(_ pattern: String, value: String) throws -> Bool { try Session().matches(pattern, value: value) }
    static func test(_ pattern: String, flags: String = "", value: String, validationOnly: Bool = false) throws -> Bool {
        try Session().test(pattern, flags: flags, value: value, validationOnly: validationOnly)
    }
    static func captures(_ pattern: String, flags: String = "", value: String) throws -> [String?]? { try Session().captures(pattern, flags: flags, value: value) }
    static func validNonUnicodeExpression(_ pattern: String) throws -> Bool { try Session().validNonUnicodeExpression(pattern) }

    /// Synchronous, validation-local owner. It is intentionally not Sendable.
    final class Session {
        private(set) var contextsCreated = 0
        #if canImport(JavaScriptCore)
        private var engine: (JSContext, JSValue)?
        private func prepared() throws -> (JSContext, JSValue) {
            if let engine { return engine }
            let value = try BackendMcpClientJSONSchemaPattern.contextAndFunction()
            engine = value; contextsCreated += 1
            return value
        }
        #endif
        func validate(_ pattern: String) throws {
            _ = try test(pattern, flags: "u", value: "", validationOnly: true)
        }
        func matches(_ pattern: String, value: String) throws -> Bool {
            try test(pattern, flags: "u", value: value)
        }
        /// Built-in formats preserve their own source flags. In particular Ajv's
        /// "regex" format compiles without u, unlike the schema pattern keyword.
        func test(_ pattern: String, flags: String = "", value: String,
                         validationOnly: Bool = false) throws -> Bool {
            #if canImport(JavaScriptCore)
            return try autoreleasepool {
                let (context, function) = try prepared()
                let answer = function.call(withArguments: [pattern, flags, value, validationOnly ? "validate" : "test"])
                try BackendMcpClientJSONSchemaPattern.checkException(context)
                guard let answer, answer.isBoolean else { throw BackendMcpClientJSONSchemaPattern.unavailable("The system regexp engine returned no boolean result.") }
                return answer.toBool()
            }
            #else
            throw BackendMcpClientJSONSchemaPattern.unavailable("ECMAScript regular expressions require the system JavaScriptCore framework.")
            #endif
        }
        func captures(_ pattern: String, flags: String = "", value: String) throws -> [String?]? {
            #if canImport(JavaScriptCore)
            return try autoreleasepool {
                let (context, function) = try prepared()
                let answer = function.call(withArguments: [pattern, flags, value, "captures"])
                try BackendMcpClientJSONSchemaPattern.checkException(context)
                guard let answer else { throw BackendMcpClientJSONSchemaPattern.unavailable("The system regexp engine returned no capture result.") }
                if answer.isNull { return nil }
                guard answer.isArray, let values = answer.toArray() else { throw BackendMcpClientJSONSchemaPattern.unavailable("The system regexp engine returned invalid captures.") }
                return try values.map { value -> String? in
                    if value is NSNull { return nil }
                    guard let text = value as? String else { throw BackendMcpClientJSONSchemaPattern.unavailable("The system regexp engine returned a non-string capture.") }
                    return text
                }
            }
            #else
            throw BackendMcpClientJSONSchemaPattern.unavailable("ECMAScript regular expressions require the system JavaScriptCore framework.")
            #endif
        }
        func validNonUnicodeExpression(_ pattern: String) throws -> Bool {
            do { return try test(pattern, value: "", validationOnly: true) }
            catch let error as NativeRPCError where error.code == "json-schema-pattern" { return false }
        }
    }
    private static func unavailable(_ message: String) -> NativeRPCError { .init(code: "unavailable", message: message) }
    #if canImport(JavaScriptCore)
    private static func contextAndFunction() throws -> (JSContext, JSValue) {
        guard let context = JSContext() else { throw unavailable("The system JavaScriptCore regexp context is unavailable.") }
        context.exception = nil
        guard let function = context.evaluateScript("""
            (function() {
              const compiled = new Map();
              return function(pattern, flags, value, operation) {
              const key = JSON.stringify([pattern, flags]);
              let expression = compiled.get(key);
              if (!expression) { expression = new RegExp(pattern, flags); compiled.set(key, expression); }
              expression.lastIndex = 0;
              if (operation === 'validate') return true;
              if (operation === 'test') return expression.test(value);
              const found = expression.exec(value);
              if (found === null) return null;
              return Array.prototype.slice.call(found, 1).map(function(part) {
                return part === undefined ? null : part;
              });
              };
            })()
            """), context.exception == nil, function.isObject else {
            throw unavailable("The system JavaScriptCore regexp helper could not be prepared.")
        }
        return (context, function)
    }
    private static func checkException(_ context: JSContext) throws {
        guard let exception = context.exception else { return }
        let reason = exception.toString() ?? "The ECMAScript engine refused the regular expression."
        context.exception = nil
        throw NativeRPCError(code: "json-schema-pattern", message: reason)
    }
    #endif
}
