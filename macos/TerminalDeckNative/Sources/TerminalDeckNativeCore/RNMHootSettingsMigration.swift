import Foundation

/// A pure plan for the two Hoot-owned keys in settings.json's `values` object.
/// The existing settings actor commits `patch` atomically before any reader uses
/// `values`. Removing the legacy key in that same write makes fallback one-time.
public enum RNMHootSettingsMigration {
    public static let homeKey = "hoot.home"
    public static let interactiveKey = "hoot.interactive"

    public struct Plan: Equatable, Sendable {
        public let values: NativeRPCValue
        public let patch: NativeRPCValue
        public let copiedKeys: [String]
        public let preservedKeys: [String]
        public let remappedHome: Bool
        public var needsWrite: Bool { !(patch.fields ?? []).isEmpty }
    }

    /// Pass both defaults from the one data-path owner, after its folder move
    /// succeeds. An explicitly stored new value wins, even false or "", except
    /// a pointer within the app-owned legacy home tree follows the folder move.
    /// A chosen project directory, text, provider ID or credential path is never
    /// searched/replaced. Only the moved legacy default tree can change.
    public static func plan(values: NativeRPCValue, legacyDefaultHome: String? = nil,
                            hootDefaultHome: String? = nil) -> Plan {
        guard values.fields != nil else {
            return Plan(values: values, patch: .object([]), copiedKeys: [], preservedKeys: [], remappedHome: false)
        }
        let pairs = [("copilot.home", homeKey), ("copilot.interactive", interactiveKey)]
        var next = values, changes: [NativeRPCValue.Field] = []
        var copied: [String] = [], preserved: [String] = []
        var remappedHome = false
        for (legacy, current) in pairs where values.has(legacy) || values.has(current) {
            let hasNew = values.has(current)
            var value = hasNew ? values[current] : values[legacy]
            let moved = current == homeKey
                ? movedHome(value, legacy: legacyDefaultHome, current: hootDefaultHome) : nil
            if let moved {
                value = moved
                remappedHome = true
            }
            if hasNew {
                if values.has(legacy) { preserved.append(current) }
            } else { copied.append(current) }
            if !hasNew || moved != nil {
                next = next.setting(current, value)
                changes.append(.init(current, value))
            }
            if values.has(legacy) {
                next = next.removing(legacy)
                changes.append(.init(legacy, .null))
            }
        }
        return Plan(values: next, patch: .object(changes), copiedKeys: copied,
            preservedKeys: preserved, remappedHome: remappedHome)
    }

    /// Normalize only containment comparisons, never the supplied destination
    /// spelling. Foundation can rewrite /private/tmp as the /tmp alias; output
    /// must retain the one path helper's root so folder identity stays exact.
    /// Component boundaries keep `..` escaping the proven tree out of scope.
    private static func movedHome(_ value: NativeRPCValue, legacy: String?,
                                  current: String?) -> NativeRPCValue? {
        guard let text = value.string, let legacy, let current,
              [text, legacy, current].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { return nil }
        let old = URL(fileURLWithPath: legacy, isDirectory: true).standardizedFileURL.path
        let newForComparison = URL(fileURLWithPath: current, isDirectory: true).standardizedFileURL.path
        let selected = URL(fileURLWithPath: text).standardizedFileURL.path
        guard old != "/", newForComparison != "/", old != newForComparison,
              selected == old || selected.hasPrefix(old + "/") else { return nil }
        let relative = selected == old ? "" : String(selected.dropFirst(old.count + 1))
        let translated = relative.isEmpty ? current
            : current + (current.hasSuffix("/") ? "" : "/") + relative
        return .string(translated)
    }

    /// Local persisted origin fields have Hoot semantics. This must only be
    /// called for a known origin field; provider/defaultProvider must keep the
    /// separate GitHub CLI ID. Wire encoding remains a transport-owner choice.
    public static func storedHootOrigin(_ origin: NativeRPCValue) -> NativeRPCValue {
        origin == .string("copilot") ? .string("hoot") : origin
    }

    /// Read compatibility for local UI projections while old wire senders
    /// remain active. Only the two exact semantic origin IDs are recognized.
    public static func isHootOrigin(_ origin: String?) -> Bool {
        origin == "hoot" || origin == "copilot"
    }
}
