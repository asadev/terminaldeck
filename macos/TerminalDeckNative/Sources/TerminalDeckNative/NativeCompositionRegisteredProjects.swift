import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    nonisolated static func registeredProjects(registry: NativeChannelRegistry, context: NativeRPCContext) async throws -> [PROJProject] {
        try PROJProjects.registeredProjects(await registry.invoke("project-registry:list", context: context, arguments: []))
    }
}
