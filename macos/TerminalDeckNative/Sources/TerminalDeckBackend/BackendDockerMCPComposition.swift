import Foundation
import TerminalDeckNativeCore

/// Docker and Apps join the actual core catalogue used by sessions and Hoot.
/// Raw contribution handlers never become a second, ungated control door.
public enum BackendDockerMCPComposition {
    public typealias Validate = @Sendable (String, NativeRPCValue) throws -> Void
    public typealias Summary = @Sendable (String, NativeRPCValue) -> String
    public typealias Preflight = @Sendable (BackendDeckCoreSecurityCallContext, String, NativeRPCValue) async throws -> Void

    public static func bundle(registrations: [(BackendMCPTool, BackendNativeMCPServer.Handler)],
                              joins: BackendCompositionProductionBindings,
                              validate: @escaping Validate, summary: @escaping Summary,
                              preflight: @escaping Preflight) throws -> BackendDeckCoreCatalogueBundle {
        let metadata = registrations.map { tool, _ in
            BackendDeckCoreCatalogueMetadata(tool: tool,
                title: tool.id.replacingOccurrences(of: ".", with: " "), index: tool.description)
        }
        let policies = registrations.map { tool, handler in
            joins.wrapped(BackendDeckCoreSecurityToolPolicy(tool: tool,
                summary: { arguments, _ in summary(tool.id, arguments) },
                precheck: { arguments, _ in try validate(tool.id, arguments) },
                precheckAsync: { arguments, context in
                    try await preflight(context, tool.id, arguments)
                },
                // Explicit owner consent even for attended callers or keys
                // whose generic settings otherwise permit standing approval.
                ownerMustAnswer: { _ in tool.tier != .read },
                redactArgs: { BackendDockerMCPMasker.arguments($0) },
                run: { arguments, context in
                    let reply = try await joins.invokeNative(tool: tool.id, handler: handler,
                                                             arguments: arguments, context: context)
                    if reply.isError {
                        let code = reply.structuredContent?["error"]["code"].string ?? "unavailable"
                        let message = reply.content.compactMap { $0["text"].string }.joined(separator: "\n")
                        throw NativeRPCError(code: code,
                            message: message.isEmpty ? "This server operation is unavailable." : BackendDockerMCPMasker.text(message))
                    }
                    let text = reply.content.compactMap { $0["text"].string }.joined(separator: "\n")
                    let value = reply.structuredContent ?? (try? NativeRPCValue.parseJSON(Data(text.utf8))) ?? .string(text)
                    let masked = BackendDockerMCPMasker.value(value)
                    return BackendDeckCoreSecurityToolOutput(value: masked, summary: masked)
                }))
        }
        return try BackendDeckCoreCatalogueBundle(metadata: metadata, policies: policies)
    }
}
