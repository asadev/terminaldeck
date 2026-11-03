import Foundation
import TerminalDeckNativeCore

/// SETTINGS-TRUTH #10 (12 Oct): the local tasks address honours an outside AI app's key the same way the MCP
/// doors do. A key's "What it may do" (Look only / Work / Full control) and its folders decide what a request
/// on the tasks address may change. Reads (GET) are always allowed; a CRM-only key exists to send tasks, so it
/// keeps sending them.
public enum BackendTaskKeyAccess {
    public static let lookOnlyRefusal = "This key may only look. To let it create, assign, cancel or change tasks, set it to Work or Full control in Settings › Outside AI apps."
    public static let folderRefusal = "That project is outside the folders this key may use. Add the folder to the key in Settings › Outside AI apps."

    /// nil when the request may go on; otherwise the plain refusal.
    public static func refusal(key: NativeRPCValue, method: String, body: Data) -> String? {
        guard key["crmOnly"].bool != true, method.uppercased() != "GET" else { return nil }
        guard BackendDeckCoreSecurityAccessKeys.tiersFor(key["level"].string ?? "look").contains(.act) else { return lookOnlyRefusal }
        let folders = key["folders"].elements?.compactMap(\.string) ?? []
        guard !folders.isEmpty, !body.isEmpty,
              let input = try? NativeRPCValue.parseJSON(body, maximumBytes: 256 * 1024),
              let project = input["project"].string, !project.isEmpty else { return nil }
        let limits = NativeRPCValue.object([.init("folders", .array(folders.map(NativeRPCValue.string)))])
        return BackendTaskAPI.folderAllowed(limits, path: project) ? nil : folderRefusal
    }
}
