import Foundation
import TerminalDeckNativeCore

/// The keepIdentity:true redaction path from redact.ts, used for MCP config
/// that an agent may send back to edit. Real folder paths must remain usable.
/// Every rule lives in BackendSharedRedact; this only fixes the options.
public enum BackendDeckCoreEventsRedaction {
    private static let options = BackendSharedRedactOptions(keepIdentity: true)
    public static func value(_ value: NativeRPCValue) -> NativeRPCValue { BackendSharedRedact.redactValue(value, options: options) }
    public static func withoutSecrets(_ value: NativeRPCValue, depth: Int = 0) -> NativeRPCValue { BackendSharedRedact.withoutSecrets(value, depth: depth) }
    public static func redact(_ text: String, extraSecrets: [String] = []) -> String {
        BackendSharedRedact.redact(text, options: .init(extraSecrets: extraSecrets, keepIdentity: true))
    }
    public static func looksSecret(_ value: String) -> Bool { BackendSharedRedact.looksSecret(value) }
}
