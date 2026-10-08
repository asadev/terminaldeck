import Foundation
import TerminalDeckNativeCore

/// Add these definitions to the EXISTING deck-tools core gate and catalogue.
/// No second MCP server, caller table, approval flag or project grant.
public enum BackendSFXMCP {
    public static let toolIDs = ["fixed.setup_preview", "fixed.setup_prepare", "fixed.setup_apply"]
    public static func definitions(service: BackendSFXSetupService, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        let previewSchema = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"project":{"type":"string"},"checkCommand":{"type":"string","description":"Optional one-line local test or help command when no useful default is detected. Preview never runs it."}},"required":["project"],"additionalProperties":false}"#.utf8))
        let applySchema = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"project":{"type":"string"},"token":{"type":"string","description":"The unexpired token returned by setup_preview. It pins the reviewed settings and command."}},"required":["project","token"],"additionalProperties":false}"#.utf8))
        let descriptions: [(String, String, String, BackendMCPTier, NativeRPCValue)] = [
            ("fixed.setup_preview", "fixed_setup_preview", "Preview detected Stays Fixed setup without writing project files or downloading anything. Returns coverage, missing steps and the settings to review. If prepareNeeded, ask the owner to use fixed.setup_prepare. If commandNeeded, offer one local help or test command; no command is executed by this preview.", .read, previewSchema),
            ("fixed.setup_prepare", "fixed_setup_prepare", "Ask the owner to prepare Stays Fixed's own pinned runtime, then return the same setup preview. Downloads only on this explicit approved action. Does not run the chosen command or write project settings.", .alter, previewSchema),
            ("fixed.setup_apply", "fixed_setup_apply", "Ask the owner to apply the exact reviewed Stays Fixed setup. Pass the preview token; expired previews, changed settings and existing config files are refused. Creates settings and adds ignore lines. The first check remains a separate explicit action, followed by owner review and fixed.mark_good.", .alter, applySchema)
        ]
        return try descriptions.map { id, wire, description, tier, schema in
            let spec = try BackendMCPTool(id: id, wireName: wire, description: description, inputSchema: schema, tier: tier)
            return BackendDeckToolsDefinition(spec: spec, title: id == "fixed.setup_preview" ? "Review Stays Fixed setup" : id == "fixed.setup_prepare" ? "Prepare Stays Fixed" : "Apply reviewed Stays Fixed setup", index: description) { context, args in
                await BackendDeckToolsSupport.reply {
                    guard args.fields != nil, args.fields!.allSatisfy({ ["project", id == "fixed.setup_apply" ? "token" : "checkCommand"].contains($0.key) }) else { throw BackendDeckToolsArgs.bad("Use only project and the setup token or optional checkCommand.") }
                    guard context.allowedTiers.contains(tier), !context.cancellation.isCancelled else { throw NativeRPCError(code: "not-permitted", message: "This caller cannot use that setup action.") }
                    let requested = try BackendDeckToolsArgs.str(args, "project")
                    let known = try await access.knownFolder(context, requested)
                    let project = try await access.runnableProject(context, known)
                    let command = try BackendDeckToolsArgs.optStr(args, "checkCommand")
                    let token = id == "fixed.setup_apply" ? try BackendDeckToolsArgs.str(args, "token") : ""
                    let sentence: String
                    if id == "fixed.setup_apply" { sentence = try await service.approvalSummary(project, token: token) }
                    else if id == "fixed.setup_prepare" { sentence = "Prepare Stays Fixed's pinned runtime on this Mac (about 60 MB), then preview setup for \(project). No project settings or chosen commands run yet." }
                    else { sentence = "Read the Stays Fixed setup preview for \(project)." }
                    try await access.authorize(context, id, args, tier, sentence, tier != .read)
                    if context.cancellation.isCancelled { throw CancellationError() }
                    // Re-resolve project grants after the owner answered.
                    _ = try await access.runnableProject(context, try await access.knownFolder(context, project))
                    let value = id == "fixed.setup_apply" ? try await service.apply(project, token: token) : try await service.preview(project, checkCommand: command, prepareRuntime: id == "fixed.setup_prepare")
                    try await access.record(context, id, args, BackendStaysFixedRead.object([("ok", value["ok"]), ("canApply", value["canApply"]), ("prepareNeeded", value["prepareNeeded"])]))
                    return .value(value)
                }
            }
        }
    }
}
