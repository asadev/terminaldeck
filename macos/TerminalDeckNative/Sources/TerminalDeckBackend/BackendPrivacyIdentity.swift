import Foundation
import TerminalDeckNativeCore

/// No TCC database access, broad resets, grant requests, or guessed old bundle IDs.
/// The shipped legacy keepers are bare executables: their signing IDs are not
/// registered app bundle IDs that tccutil can reliably remove.
public enum BackendPrivacyIdentity {
    public struct Pane: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let anchor: String
        public var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor)! }
    }
    public static let panes: [Pane] = [
        .init(id: "screen", title: "Screen & System Audio Recording", anchor: "Privacy_ScreenCapture"),
        .init(id: "accessibility", title: "Accessibility", anchor: "Privacy_Accessibility"),
        .init(id: "automation", title: "Automation", anchor: "Privacy_Automation"),
        .init(id: "files", title: "Files & Folders", anchor: "Privacy_FilesAndFolders"),
        .init(id: "disk", title: "Full Disk Access", anchor: "Privacy_AllFiles"),
        .init(id: "camera", title: "Camera", anchor: "Privacy_Camera"),
        .init(id: "microphone", title: "Microphone", anchor: "Privacy_Microphone"),
        .init(id: "network", title: "Local Network", anchor: "Privacy_LocalNetwork"),
    ]
    public static let explanation = "macOS asks separately for each kind of access. Keep the current Terminal Deck entry. Your choices should survive app updates; macOS may still ask again when its own rules change."
    public static let cleanupSteps = [
        "First use the updated session helper and confirm that its access appears under Terminal Deck. If it still asks for TerminalDeckNativeHelper, keep the entries and report the problem.",
        "Select an old TerminalDeckNativeHelper entry and click the minus (−) button. Repeat for the other old helper entries. Keep Terminal Deck and every other app.",
        "If a list has no minus button, leave the old entry switched off. This app cannot safely remove it for you."
    ]
    public static var guide: NativeRPCValue {
        .object([.init("explanation", .string(explanation)), .init("automaticResetAvailable", .bool(false)),
            .init("steps", .array(cleanupSteps.map(NativeRPCValue.string))),
            .init("panes", .array(panes.map { .object([.init("id", .string($0.id)), .init("title", .string($0.title)), .init("url", .string($0.url.absoluteString))]) }))])
    }
}

public enum BackendPrivacyMCP {
    public static let toolIDs: Set<String> = ["privacy.cleanup_guide", "privacy.open_settings"]
    public static func definitions(access: BackendDeckToolsAppAccess,
                                   openSettings: @escaping @Sendable (URL) async -> Bool) throws -> [BackendDeckToolsDefinition] {
        let guideSchema = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8))
        let openSchema = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"pane":{"type":"string","enum":["screen","accessibility","automation","files","disk","camera","microphone","network"]}},"required":["pane"],"additionalProperties":false}"#.utf8))
        return try [false, true].map { opens in
            let id = opens ? "privacy.open_settings" : "privacy.cleanup_guide"
            let tier: BackendMCPTier = opens ? .act : .read
            let spec = try BackendMCPTool(id: id, wireName: opens ? "privacy_open_settings" : "privacy_cleanup_guide",
                description: opens ? "Ask the person, then open one macOS privacy list. Does not change grants or remove entries." : "Read the same old-helper cleanup steps shown in Settings > Privacy. Does not request or change any permission.",
                inputSchema: opens ? openSchema : guideSchema, tier: tier)
            return BackendDeckToolsDefinition(spec: spec, title: opens ? "Open macOS privacy settings" : "Remove old Terminal Deck entries") { context, args in
                await BackendDeckToolsSupport.reply {
                    guard let fields = args.fields, fields.allSatisfy({ opens && $0.key == "pane" }),
                          context.allowedTiers.contains(tier), !context.cancellation.isCancelled else {
                        throw NativeRPCError(code: "not-permitted", message: "Use only the requested privacy pane with a permitted caller.")
                    }
                    let pane = opens ? BackendPrivacyIdentity.panes.first { $0.id == args["pane"].string } : nil
                    if opens && pane == nil { throw BackendDeckToolsArgs.bad("Choose a privacy pane from the cleanup guide.") }
                    try await access.authorize(context, id, args, tier, pane.map { "Open System Settings > Privacy & Security > " + $0.title + ". No permission will be changed." } ?? "Read the old helper cleanup steps.", opens)
                    if context.cancellation.isCancelled { throw CancellationError() }
                    if let pane, !(await openSettings(pane.url)) { throw NativeRPCError(code: "unavailable", message: "macOS could not open that privacy list.") }
                    try await access.record(context, id, args, .object([.init("opened", .bool(opens))]))
                    return .value(BackendPrivacyIdentity.guide)
                }
            }
        }
    }
}
