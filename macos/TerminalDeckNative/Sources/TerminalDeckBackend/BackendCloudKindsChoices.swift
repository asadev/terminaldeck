import Foundation
import TerminalDeckNativeCore

/// Same everywhere (15 Nov): what the app's screens remember (side-panel pins and their order, open sections, page
/// views), read from and written to the app's own defaults for the settings kind (`CloudBrainSettings.Source.choice`).
/// Only keys on `CloudBrainSettings.travels` are ever read or written: the same store also holds the system's entries.
/// After a write from another device, `arrived` names the keys so the screens that read them once at start reload.
public final class BackendCloudKindsChoices: @unchecked Sendable {
    /// Posted on the main queue after values from another device were written; `userInfo["keys"]` = [String].
    public static var arrivedNotification: Notification.Name { CloudSyncChoices.choicesArrived }
    private let defaults: UserDefaults
    private let lock = NSLock()
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Every travelling choice this device holds now, as plain values.
    public func values() -> [String: NativeRPCValue] {
        lock.withLock {
            var result: [String: NativeRPCValue] = [:]
            for (key, object) in defaults.dictionaryRepresentation() where CloudBrainSettings.rule(.choice, key) != nil {
                if let value = Self.value(object) { result[key] = value }
            }
            return result
        }
    }
    /// Writes one value exactly as the screens keep it (text, on/off, number or list); nil removes it.
    public func write(_ key: String, _ value: NativeRPCValue?) throws {
        guard CloudBrainSettings.rule(.choice, key) != nil else { throw CloudFailure.invalidRequest }
        try lock.withLock {
            guard let value, !value.isNullish else { defaults.removeObject(forKey: key); return }
            guard let object = Self.object(value) else { throw CloudFailure.invalidRequest }
            defaults.set(object, forKey: key)
        }
    }
    /// The screens reload what they read once at start (side-panel pins). Display only.
    public func announce(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.arrivedNotification, object: nil, userInfo: ["keys": keys]) }
    }

    /// A defaults value as a plain value: text, on/off, finite number, or a list/structure of those. Data and dates
    /// are not choices that travel (nil).
    static func value(_ object: Any) -> NativeRPCValue? {
        switch object {
        case let text as String: return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let double = number.doubleValue
            return double.isFinite ? .number(double) : nil
        case let list as [Any]:
            var items: [NativeRPCValue] = []
            for item in list { guard let value = value(item) else { return nil }; items.append(value) }
            return .array(items)
        case let map as [String: Any]:
            var fields: [NativeRPCValue.Field] = []
            for key in map.keys.sorted() { guard let value = value(map[key]!) else { return nil }; fields.append(.init(key, value)) }
            return .object(fields)
        default: return nil
        }
    }
    /// The defaults form of a plain value (the reverse of `value`).
    static func object(_ value: NativeRPCValue) -> Any? {
        switch value {
        case .string(let text): return text
        case .bool(let flag): return flag
        case .number(let number): return number.isFinite ? number : nil
        case .array(let items):
            var list: [Any] = []
            for item in items { guard let made = object(item) else { return nil }; list.append(made) }
            return list
        case .object(let fields):
            var map: [String: Any] = [:]
            for field in fields { guard let made = object(field.value) else { return nil }; map[field.key] = made }
            return map
        default: return nil
        }
    }
}
