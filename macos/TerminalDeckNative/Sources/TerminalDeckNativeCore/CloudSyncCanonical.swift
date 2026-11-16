import Foundation
import JavaScriptCore

/// RFC 8785 needs ECMAScript's number formatting, including values between 1e-6 and 1e21.
/// The system formatter is shared under a lock; large imports must not create a VM for each hash.
public enum CloudSyncCanonical {
  private static let formatter = Formatter()
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let value = try NativeRPCValue.parseJSON(JSONEncoder().encode(value))
    return try formatter.encode(value)
  }
  private final class Formatter: @unchecked Sendable {
    private let lock = NSLock()
    private let context = JSContext()
    func encode(_ value: NativeRPCValue) throws -> Data {
      lock.lock()
      defer { lock.unlock() }
      guard let context else { throw CloudFailure.unavailable }
      return try autoreleasepool {
        func write(_ value: NativeRPCValue) throws -> String {
          switch value {
          case .null: return "null"
          case .bool(let bool): return bool ? "true" : "false"
          case .string(let string): return OrderedJSON.quote(string)
          case .number(let number):
            guard number.isFinite, let text = JSValue(double: number, in: context)?.toString() else { throw CloudFailure.invalidRequest }
            return text
          case .array(let array): return "[" + (try array.map(write)).joined(separator: ",") + "]"
          case .object(let fields):
            guard Set(fields.map(\.key)).count == fields.count else { throw CloudFailure.invalidRequest }
            return "{" + (try fields.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }.map {
              OrderedJSON.quote($0.key) + ":" + (try write($0.value))
            }).joined(separator: ",") + "}"
          case .bytes, .missing: throw CloudFailure.invalidRequest
          }
        }
        return Data(try write(value).utf8)
      }
    }
  }
}
