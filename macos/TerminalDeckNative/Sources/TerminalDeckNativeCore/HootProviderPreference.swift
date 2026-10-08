import Foundation

/// Hoot owns this key; existing settings tools protect the entire hoot. prefix.
public enum HootProviderPreference {
    public static let key = "hoot.provider"
    public static func resolve(_ value: NativeRPCValue) throws -> HootChatProvider {
        if value.isNullish { return .claude }
        guard let text = value.string, let provider = HootChatProvider(rawValue: text) else {
            throw NativeRPCError.invalidArguments("Hoot provider must be claude, codex or gemini.")
        }
        return provider
    }
}
