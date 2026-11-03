import AppKit
import Foundation
import UniformTypeIdentifiers
import TerminalDeckBackend

#if TD_HOST_ACCOUNT_BRIDGE
typealias HOSTNativeCompositionClientsProfiles = any BackendHOSTProfileViewReading
#else
typealias HOSTNativeCompositionClientsProfiles = BackendAccountProfileStore
#endif
import TerminalDeckNativeCore

/// Only the local window receives these file and consent capabilities. Remote
/// callers use their authenticated domain adapters, never these settings APIs.
@MainActor enum NativeCompositionClients {
    static func runtimeDependencies(dataRoot: URL, configuration: EngineConfiguration,
                                    window: @escaping @MainActor @Sendable () -> NSWindow?,
                                    report: @escaping @Sendable (String) -> Void) -> BackendCompositionClientsDependencies {
        var dependencies = appKitDependencies(window: window, report: report)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TerminalDeckJSCorePluginHelper")
        do { dependencies.pluginRuntimeExecutable = try BackendJSCoreTransportFactory(helperExecutable: helper).runtimePath() }
        catch { report("Plugins: " + error.localizedDescription) }
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates += [resources.appendingPathComponent("staysfixed/package/staysfixed-0.15.0-neutral.tgz"),
                resources.appendingPathComponent("staysfixed/staysfixed-0.15.0-neutral.tgz")]
        }
        if let archive = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            do { dependencies.staysFixedProvisioning = try BackendNodelessStaysFixedRuntime(userData: dataRoot, bundledProduct: archive) }
            catch { report("Stays Fixed: " + error.localizedDescription) }
        }
        return dependencies
    }
    static func appKitDependencies(window: @escaping @MainActor @Sendable () -> NSWindow?,
                                  report: @escaping @Sendable (String) -> Void) -> BackendCompositionClientsDependencies {
        var dependencies = BackendCompositionClientsDependencies(report: report)
        dependencies.saveChooser = { name in try await chooseSave(name: name, window: window) }
        dependencies.openChooser = { try await chooseOpen(window: window) }
        dependencies.pluginsDesktop = pluginsDesktop
        dependencies.knowledgeConsent = { request in try await confirmKnowledgeShare(request, window: window) }
        return dependencies
    }

    private static var pluginsDesktop: BackendPluginsDesktop {
        BackendPluginsDesktop(openFolder: { url in
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            guard opened else { throw NativeRPCError(code: "unavailable", message: "The plugins folder could not be opened.") }
        }, trash: { url in _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil) })
    }

    static func memoryEnvironment(profiles: HOSTNativeCompositionClientsProfiles, userData: URL,
                                  hootMemory: @escaping @Sendable () async -> String?,
                                  hootActionLogger: @escaping @Sendable () async -> BackendMemoryActionLogger? = { nil }) -> BackendCompositionClientsMemoryEnvironment {
        BackendCompositionClientsMemoryEnvironment(profiles: profiles, userData: userData, hootMemory: hootMemory,
            trash: { path in
                try await MainActor.run {
                    _ = try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                }
            }, hootActionLogger: hootActionLogger)
    }

    private static func chooseSave(name: String, window: @MainActor @Sendable () -> NSWindow?) async throws -> String? {
        guard let parent = window() else { throw NativeRPCError(code: "unavailable", message: "There is no app window to choose the exported MCP file.") }
        let panel = NSSavePanel()
        panel.title = "Export MCP server"
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: parent) { response in continuation.resume(returning: response == .OK ? panel.url?.path : nil) }
        }
    }

    private static func chooseOpen(window: @MainActor @Sendable () -> NSWindow?) async throws -> String? {
        guard let parent = window() else { throw NativeRPCError(code: "unavailable", message: "There is no app window to choose an MCP definition.") }
        let panel = NSOpenPanel()
        panel.title = "Import MCP server"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: parent) { response in continuation.resume(returning: response == .OK ? panel.url?.path : nil) }
        }
    }

    private static func confirmKnowledgeShare(_ request: BackendKnowledgeShareRequest,
                                               window: @MainActor @Sendable () -> NSWindow?) async throws -> Bool {
        guard let parent = window() else { throw NativeRPCError(code: "unavailable", message: "There is no app window to approve knowledge sharing.") }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Let this project read another project’s knowledge?"
        alert.informativeText = "\(request.to) will be able to read the \(request.records) knowledge records kept for \(request.from)."
        alert.addButton(withTitle: "Don’t share")
        alert.addButton(withTitle: "Share")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: parent) { response in continuation.resume(returning: response == .alertSecondButtonReturn) }
        }
    }
}
