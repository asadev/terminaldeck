import Foundation
import TerminalDeckNativeCore

/// Decorates the production factory's actual policy/run wrapper. Registration
/// stays additive; the sole core still owns consent, budgets and action rows.
public enum BackendGHMCPPolicy {
    public typealias ScopePrecheck = @Sendable (NativeRPCValue, BackendDeckCoreSecurityCallContext) async throws -> Void

    public static func decorate(_ seed: BackendDeckCoreSecurityToolPolicy,
                                scopePrecheck: ScopePrecheck? = nil) throws -> BackendDeckCoreSecurityToolPolicy {
        guard let entry = BackendGHMCPCatalogue.entries().first(where: { $0.id == seed.tool.id }),
              seed.tool.tier == entry.tier,
              seed.tool.inputSchema == entry.schema else {
            throw NativeRPCError.invalidArguments("The GitHub policy must wrap the exact native GitHub tool definition and tier.")
        }
        let operation = entry.operation
        return BackendDeckCoreSecurityToolPolicy(tool: seed.tool, aliases: seed.aliases, audience: seed.audience,
            keyRequiresTasks: seed.keyRequiresTasks, spendsDeviceInput: seed.spendsDeviceInput,
            summary: { arguments, _ in BackendGHMCPTools.summary(operation: operation, arguments: arguments) },
            precheck: { arguments, context in
                try seed.precheck?(arguments, context)
                try BackendGHMCPTools.validate(operation: operation, arguments: arguments)
            },
            precheckAsync: { arguments, context in
                try Task.checkCancellation()
                if context.cancellation.isCancelled { throw CancellationError() }
                try await seed.precheckAsync?(arguments, context)
                switch context.caller.kind {
                case .remote:
                    throw BackendDeckCoreSecurityRefusal(.notGranted, "The paired device cannot use this computer's GitHub account. Use the app here or a granted access key.")
                case .session:
                    guard ![BackendGHOperation.reposList, .reposClone, .notificationsList, .notificationsRead].contains(operation),
                          arguments["projectPath"].string != nil, arguments["repo"].string != nil,
                          scopePrecheck != nil else {
                        throw BackendDeckCoreSecurityRefusal(.notGranted, "A session needs the exact repository of its granted project. Global GitHub access and clone are unavailable to sessions.")
                    }
                case .key where context.caller.folders != nil:
                    guard ![BackendGHOperation.reposList, .reposClone, .notificationsList, .notificationsRead].contains(operation),
                          arguments["projectPath"].string != nil, arguments["repo"].string != nil,
                          scopePrecheck != nil else {
                        throw BackendDeckCoreSecurityRefusal(.notGranted, "This access key is limited to projects. Supply the exact GitHub repository of a granted project; global GitHub access is unavailable.")
                    }
                case .local, .key:
                    if (operation == .reposClone || arguments.has("projectPath")), scopePrecheck == nil {
                        throw BackendDeckCoreSecurityRefusal(.notGranted, "The app must supply its current folder grant check before this GitHub action can run.")
                    }
                }
                try await scopePrecheck?(arguments, context)
                try Task.checkCancellation()
                if context.cancellation.isCancelled { throw CancellationError() }
            }, escalate: seed.escalate,
            ownerMustAnswer: { arguments in
                if operation.isWrite { return true }
                return try seed.ownerMustAnswer?(arguments) ?? false
            },
            redactArgs: { arguments in BackendGHMCPTools.redacted(try seed.redactArgs?(arguments) ?? arguments) },
            run: seed.run)
    }
}
