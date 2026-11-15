import Foundation
import TerminalDeckNativeCore

/// One composition-root entry point for the complete deck-tools contribution.
/// The factories' required runtime/environment callbacks must already be bound
/// to the shared core consent, budget, provenance and action-log owner. This
/// registrar neither invents those services nor creates a second gate/server.
public enum BackendDeckToolsRegistration {
    public static let ownerID = "backend.deck-tools"

    public struct Installed: Sendable {
        public let areas: [BackendDeckCoreToolArea]
        /// Join with core/Safari/client metadata for tools.describe, source
        /// aliases, audience filtering and progressive catalogue disclosure.
        public let metadata: [BackendDeckCoreCatalogueMetadata]
        public let toolIDs: [String]
    }

    /// Pass the definitions from every factory in deck-tools-HANDOFF.md once;
    /// include the shared browser.lift_request definition only once. Invoke
    /// before starting the endpoint, after the source gate callbacks are wired.
    ///
    /// All identity/metadata/area checks precede the one atomic server mutation.
    /// Repeating this call replaces only this registrar's own contribution;
    /// collisions with another owner fail without changing either contribution.
    /// Core bundles/policies retain the real runtime gates described above.
    @discardableResult
    public static func register(on server: BackendNativeMCPServer,
                                definitions: [BackendDeckToolsDefinition]) async throws -> Installed {
        let supplied = Set(definitions.map { $0.spec.id })
        let expected = try expectedIDs(supplied: supplied)
        guard supplied == expected, definitions.count == expected.count else {
            let missing = expected.subtracting(supplied).sorted().joined(separator: ", ")
            let extra = supplied.subtracting(expected).sorted().joined(separator: ", ")
            throw NativeRPCError.invalidArguments(
                "The deck-tools registration requires each source tool exactly once. "
                + "Missing: \(missing.isEmpty ? "none" : missing). "
                + "Extra: \(extra.isEmpty ? "none" : extra). "
                + "Duplicate entries: \(definitions.count - supplied.count).")
        }

        let metadata = definitions.map(\.catalogueMetadata)
        _ = try BackendDeckCoreCatalogueRegistry(metadata: metadata)
        let areas = try BackendDeckToolsSupport.areas(definitions: definitions)
        var contribution: [(BackendMCPTool, BackendNativeMCPServer.Handler)] = []
        for area in areas {
            for tool in area.tools {
                guard let handler = area.handlers[tool.id] else {
                    throw BackendDeckToolsSupport.unavailable("the \(tool.id) registration handler")
                }
                contribution.append((tool, handler))
            }
        }
        try Task.checkCancellation()
        try await server.replaceTools(ownerID: ownerID, tools: contribution)
        return Installed(areas: areas, metadata: metadata, toolIDs: areas.flatMap { $0.tools.map(\.id) })
    }

    /// The Devices window's own pair (MAC-NEXT-13): its rows and its Remove, supplied whole or not at all.
    public static let devicesPageIDs: Set<String> = ["devices.page", "devices.remove", "devices.rename", "devices.sign_out"]

    /// The exact tool set the start-up check demands for what the composition supplied: every required source tool,
    /// plus each optional family the composition touched, whole. `register` refuses anything else, so a supplied id
    /// outside this set is the "Extra" that stops the app at start (MAC-NEXT-13b; tested against the app's own sources).
    public static func expectedIDs(supplied: Set<String>) throws -> Set<String> {
        let rootIDs = try BackendDeckToolsCatalogue.entries().map { $0.spec.id }
        let sessionIDs = BackendDeckToolsSessionsCatalogue.entries.map(\.id)
        let appIDs = try BackendDeckToolsAppMetadata.entries().map { $0.spec.id }
        let machineIDs = try BackendDeckToolsMachinesCatalogue.rows().map {
            try $0["id"].requireString("source tool id", nonempty: true)
        }
        // The session panel optionally supplies one complete attachment family.
        // A partially wired family must fail before changing the server, just as
        // missing, unknown or duplicate source tools do.
        let attachmentIDs: Set<String> = ["devices.attached", "devices.attach", "devices.detach", BackendANDROIDPhoneOpenApp.id]
        let attachTools: Set<String> = supplied.isDisjoint(with: attachmentIDs) ? [] : attachmentIDs
        let recordingIDs: Set<String> = ["devices.record", "devices.recording"]
        let recordTools: Set<String> = supplied.isDisjoint(with: recordingIDs) ? [] : recordingIDs
        // A recorder requires the shared attachment owner and its complete tool family.
        guard recordTools.isEmpty || !attachTools.isEmpty else {
            throw NativeRPCError.invalidArguments("Device recording requires the session's shared attachment tools.")
        }
        // #108: the Simulators page's simulators.* family, supplied whole or not at all.
        let simulatorIDs = Set(BackendFIXESSimulatorMCP.ids)
        let simulatorTools: Set<String> = supplied.isDisjoint(with: simulatorIDs) ? [] : simulatorIDs
        let chatIDs: Set<String> = ["sessions.chat", "sessions.start_agent"]
        let libraryTools = supplied.intersection(["sessions.chat_library", "sessions.chat_feature", "sessions.chat_organize", "sessions.chat_provider", "sessions.chat_diffs", "sessions.chat_children", "sessions.chat_terminal", "sessions.chat_fork", "sessions.chat_rewind"])
        let devicePanelTools = supplied.intersection(["sessions.device_panels"])
        guard libraryTools.isEmpty || chatIDs.isSubset(of: supplied) else {
            throw NativeRPCError.invalidArguments("Native Chat extensions require the shared Chat tools.")
        }
        let chatTools: Set<String> = (supplied.isDisjoint(with: chatIDs) ? [] : chatIDs).union(supplied.contains("sessions.conversations") ? ["sessions.conversations"] : []).union(supplied.contains("developer.session_host_restart") ? ["developer.session_host_restart"] : [])
        // Native side-panel actions are an optional, complete family too.
        let sidebarIDs: Set<String> = ["sidebar.pages.list", "sidebar.page.open", "sidebar.page.pin", "sidebar.pages.reorder"]
        let sidebarTools: Set<String> = supplied.isDisjoint(with: sidebarIDs) ? [] : sidebarIDs
        let queueTools: Set<String> = supplied.contains("chats.queue") ? ["chats.queue"] : []
        let captureTools = supplied.intersection(["browser.feedback", "windows.check"])
        // Privacy is an optional, complete family for the native Mac settings page.
        let privacyIDs = BackendPrivacyMCP.toolIDs
        let privacyTools: Set<String> = supplied.isDisjoint(with: privacyIDs) ? [] : privacyIDs
        let devicesPageTools: Set<String> = supplied.isDisjoint(with: devicesPageIDs) ? [] : devicesPageIDs
        // L5: the Code page's code.* family, supplied whole or not at all.
        let codePageTools: Set<String> = supplied.isDisjoint(with: BackendCodeBackupTools.pageIDs) ? [] : BackendCodeBackupTools.pageIDs
        // L4: the Cloud page's cloud.* family, supplied whole or not at all. Delete rule (L6, 15 Nov): one shape only
        // (reads, cloud.use_version, cloud.delete, cloud.not_here, cloud.bring_back); the Bin tools are retired
        // (`BackendCloudManagerTools.retiredIDs`) and are never expected, so supplying one stops the start as "Extra".
        let cloudPageTools: Set<String> = supplied.isDisjoint(with: BackendCloudManagerTools.pageIDs) ? [] : BackendCloudManagerTools.pageIDs
        // L3: the Cloud folder's cloud.folder / cloud.folder_add, supplied whole or not at all.
        let cloudFolderTools: Set<String> = supplied.isDisjoint(with: BackendCloudFolderTools.pageIDs) ? [] : BackendCloudFolderTools.pageIDs
        // L3 slice 2: artifacts that travel (cloud.artifacts only since the delete rule), whole or not at all.
        let cloudArtifactsTools: Set<String> = supplied.isDisjoint(with: BackendCloudArtifactsTools.pageIDs) ? [] : BackendCloudArtifactsTools.pageIDs
        // Project secret files (14 Nov): cloud.project_secrets (read only), supplied whole or not at all.
        let projectSecretTools: Set<String> = supplied.isDisjoint(with: BackendProjectSecretFilesTools.pageIDs) ? [] : BackendProjectSecretFilesTools.pageIDs
        let expected = Set(rootIDs + sessionIDs + appIDs + machineIDs).union(BackendAIRReadinessTools.toolIDs).union(BackendSFXMCP.toolIDs).union(attachTools).union(recordTools).union(simulatorTools).union(chatTools).union(libraryTools).union(devicePanelTools).union(sidebarTools).union(queueTools).union(captureTools).union(privacyTools).union(devicesPageTools).union(codePageTools).union(cloudPageTools).union(cloudFolderTools).union(cloudArtifactsTools).union(projectSecretTools)
        // The Bin is by hand only: a retired Bin or delete tool is never part of any expected set, whoever lists it.
        return expected.subtracting(BackendCloudManagerTools.retiredIDs)
    }
}
