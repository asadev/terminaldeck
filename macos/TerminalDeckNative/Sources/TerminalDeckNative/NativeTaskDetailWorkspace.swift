import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: The workspace

    func loadWorkspace() async {
        // A connected system's task has no workspace on this Mac.
        guard connected == nil, EngineBridge.shared.isReady, let raw = try? await EngineBridge.shared.invoke("tasks:workspace", [taskId]) else {
            workspace = WorkspaceView(workspace: nil, refusal: nil)
            return
        }
        workspace = Self.workspaceView(raw)
    }

    static func workspaceView(_ value: Any?) -> WorkspaceView {
        guard let raw = value as? [String: Any] else { return WorkspaceView(workspace: nil, refusal: nil) }
        let refusal = raw["refusal"] as? String
        guard let w = raw["workspace"] as? [String: Any], let folder = w["folder"] as? String, let branch = w["branch"] as? String,
              let repo = w["repo"] as? String, let state = w["state"] as? String, ["active", "kept", "removed"].contains(state)
        else { return WorkspaceView(workspace: nil, refusal: refusal) }
        return WorkspaceView(workspace: WorkspaceShown(folder: folder, branch: branch, repo: repo, state: state, reason: w["reason"] as? String),
                             refusal: refusal)
    }

    var showsWorkspace: Bool {
        guard let workspace else { return false }
        return workspace.workspace != nil || workspace.refusal != nil
    }

    func openWorkspace() {
        Task {
            do {
                let answer = try await EngineBridge.shared.invoke("tasks:workspace-open", [taskId]) as? [String: Any]
                workspaceNote = TasksJSON.isTrue(answer?["ok"]) ? nil : (false, answer?["error"] as? String ?? "The folder could not be opened.")
            } catch {
                workspaceNote = (false, error.localizedDescription)
            }
        }
    }

    func removeWorkspace() {
        workspaceBusy = true
        workspaceNote = nil
        Task {
            defer { workspaceBusy = false }
            do {
                let answer = try await EngineBridge.shared.invoke("tasks:workspace-remove", [taskId]) as? [String: Any]
                if let view = answer?["view"] { workspace = Self.workspaceView(view) }
                workspaceNote = (TasksJSON.isTrue(answer?["ok"]), answer?["message"] as? String ?? "The workspace could not be removed.")
            } catch {
                workspaceNote = (false, error.localizedDescription)
            }
        }
    }

}
