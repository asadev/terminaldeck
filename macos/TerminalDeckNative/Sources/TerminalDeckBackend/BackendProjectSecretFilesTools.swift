import Foundation
import TerminalDeckNativeCore

/// Project secret files' tool (every feature ships with its tool). READ ONLY: per project, the secret files' names,
/// sizes, dates, the Mac they came from and their state. There is deliberately no tool that reads a secret's content,
/// and none that sends or places one: they travel by themselves with his saved passwords.
public enum BackendProjectSecretFilesTools {
    public static let statusID = "cloud.project_secrets"
    public static let pageIDs: Set<String> = [statusID]

    public struct Actions: Sendable {
        public var status: @Sendable () async -> BackendProjectSecretFilesStatus?
        public init(status: @escaping @Sendable () async -> BackendProjectSecretFilesStatus?) { self.status = status }
        public static let none = Actions(status: { nil })
    }
    public static let notOpen = NativeRPCError(code: "unavailable",
        message: "Project secret files travel inside saved passwords, which are not open on this Mac right now (signed out, or still starting).")

    static let description = "Which secret files of the person's projects (.env and other credential files) travel between their computers inside saved passwords: per project, each file's name, size, date, the Mac it came from and its state (travels, arrived, different on another device with theirs kept, waiting, too large, stays on this Mac because it can make a program run, not placed). Never returns a file's content. Files travel by themselves; nothing here sends or changes one."

    public static func definitions(access: BackendDeckToolsAppAccess, actions: Actions) throws -> [BackendDeckToolsDefinition] {
        let spec = try BackendMCPTool(id: statusID, wireName: statusID.replacingOccurrences(of: ".", with: "_"), description: description,
                                      inputSchema: NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)),
                                      tier: .read)
        let title = "Project secret files"
        return [BackendDeckToolsDefinition(spec: spec, title: title, index: title + " (saved passwords).") { context, args in
            try await BackendDeckToolsSupport.reply {
                guard context.allowedTools.contains(spec.id) || context.allowedTools.contains(spec.wireName), context.allowedTiers.contains(.read) else {
                    throw NativeRPCError(code: "not-granted", message: "This caller cannot read project secret files' status.")
                }
                try await access.authorize(context, statusID, args, .read, "See which project secret files travel with your saved passwords", false)
                guard let status = await actions.status() else { throw notOpen }
                return .value(answer(status))
            }
        }]
    }

    /// Names, sizes, dates and words only.
    public static func answer(_ status: BackendProjectSecretFilesStatus) -> NativeRPCValue {
        func date(_ ms: Int64?) -> NativeRPCValue { ms.map { .string(CloudSecretsLog.date($0)) } ?? .null }
        let projects: [NativeRPCValue] = status.projects.map { project in
            BackendDeckToolsSupport.object([
                ("project", .string(project.name)),
                ("files", .array(project.files.map { file in
                    BackendDeckToolsSupport.object([("name", .string(file.path)), ("bytes", .number(Double(file.bytes))),
                        ("date", date(file.at)), ("from", file.from.map(NativeRPCValue.string) ?? .null), ("state", .string(file.state)),
                        ("travels", .bool(file.travels))])
                }))
            ])
        }
        return BackendDeckToolsSupport.object([
            ("projects", .array(projects)),
            ("keepOnThisMacOnly", .bool(status.keepOnThisMac)),
            ("waitingForYourOtherMacs", .bool(status.waitingForMacs)),
            ("why", status.waitingWhy.map(NativeRPCValue.string) ?? .null),
            ("refusedFromOtherMacs", .number(Double(status.refusedArrivals))),
            ("lastLooked", date(status.lookedAt)),
        ])
    }
}
