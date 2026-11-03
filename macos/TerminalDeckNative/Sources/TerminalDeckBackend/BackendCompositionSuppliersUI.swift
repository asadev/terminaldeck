import Foundation
import AppKit
import TerminalDeckNativeCore

/// Real native picker/Finder operations, plus the app view/browser routes that
/// only the SwiftUI owner can supply. Construction opens no panel or window.
public struct BackendCompositionSuppliersUI: Sendable {
    public let pickFolder: @Sendable () async throws -> String?
    public let openFolder: @Sendable (String) async throws -> String
    public let showProject: @Sendable (String) async throws -> Bool
    public let hookOpenLink: (@Sendable (URL, String?) async throws -> BackendSessionHookOpenAnswer)?
    public init(state: BackendCompositionState, home: String,
                showProject: @escaping @Sendable (String) async throws -> Bool,
                hookOpenLink: (@Sendable (URL, String?) async throws -> BackendSessionHookOpenAnswer)? = nil) {
        self.showProject = showProject; self.hookOpenLink = hookOpenLink
        pickFolder = { await Self.pick(state: state, home: home) }
        openFolder = { path in
            await MainActor.run {
                NSWorkspace.shared.open(URL(fileURLWithPath: path)) ? "" : "Finder could not open this workspace folder."
            }
        }
    }
    @MainActor private static func pick(state: BackendCompositionState, home: String) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        let start = BackendAppProjectPicker.startDirectory(projects: state.listProjects().compactMap { $0["path"].string }, home: home)
        panel.directoryURL = URL(fileURLWithPath: start)
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url?.path : nil) }
        }
    }
}
