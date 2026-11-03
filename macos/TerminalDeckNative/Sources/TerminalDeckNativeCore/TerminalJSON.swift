import Foundation

/// JSON values as the engine sends them (JSONSerialization output), read with
/// JavaScript's `typeof` strictness: a boolean is never a number and a number
/// is never a boolean, although both arrive as `NSNumber`.
public enum TerminalJSON {
    public static func isBoolean(_ value: Any?) -> Bool {
        guard let value, let object = value as AnyObject? else { return false }
        return CFGetTypeID(object) == CFBooleanGetTypeID()
    }

    public static func bool(_ value: Any?) -> Bool? {
        guard isBoolean(value) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    public static func number(_ value: Any?) -> Double? {
        guard let value, !isBoolean(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    public static func int(_ value: Any?) -> Int? {
        guard let double = number(value), double == double.rounded() else { return nil }
        return Int(exactly: double)
    }

    /// A non-empty string, or nil.
    public static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
