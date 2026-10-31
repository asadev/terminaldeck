import Foundation

// Tasks, as the window reads them: the agents, the connections, your own tasks,
// the read-only mirror of a CRM's work, and your goals. A port of
// src/renderer/tasks/tasks-model.ts, read field by field from what the engine
// answers (never cast), so a malformed answer reads as nothing rather than a guess.
//
// Two words are kept apart on purpose. A **status** belongs to the CRM and is
// shown exactly as the CRM spells it. Queued, running and exited are this app's
// own **process states**; they are never called a status anywhere on screen.

// MARK: - Reading the engine's answers

/// Readers over the Foundation objects a JSON answer arrives as. Strict about type:
/// a JavaScript boolean is never a number here, nor a number a boolean.
public enum TasksJSON {
    public static func record(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    /// A non-empty string, else nil (the page's `text`).
    public static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// A finite number (not a boolean).
    public static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    public static func count(_ value: Any?, _ fallback: Double) -> Double { number(value) ?? fallback }

    public static func int(_ value: Any?, _ fallback: Int) -> Int {
        guard let double = number(value), abs(double) < 1e15 else { return fallback }
        return Int(double)
    }

    public static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    public static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Only a literal `true`.
    public static func isTrue(_ value: Any?) -> Bool { bool(value) == true }
}

/// A JSON null for payloads.
var jsonNull: Any { NSNull() }
func orNullValue(_ value: String?) -> Any { value.map { $0 as Any } ?? jsonNull }
func orNullValue(_ value: Double?) -> Any { value.map { $0 as Any } ?? jsonNull }
