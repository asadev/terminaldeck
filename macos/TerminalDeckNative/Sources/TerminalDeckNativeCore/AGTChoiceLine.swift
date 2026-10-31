import Foundation

/// PLAYBOOK-SEATS (12 Oct): the agent's profile shows what its latest job ran with and where each choice came from,
/// e.g. "Claude Code · opus · from the playbook: bug fix; effort high · from its own settings".
/// Order of the layers: the playbook row for the job, else the agent's own settings, else the app defaults.
public enum AGTChoiceLine {
    /// nil when the run carries no record of where its choices came from (older runs).
    public static func text(run: NativeRPCValue) -> String? {
        let sources = run["sources"]
        guard sources.fields != nil else { return nil }
        let job = run["playbook_job"].string ?? ""
        let values: [(field: String, text: String?)] = [
            ("ai", run["provider"].string.map(CodingAICatalog.label)),
            ("model", run["requested_model"].string),
            ("effort", run["requested_effort"].string.map { "effort " + $0 }),
            ("permission", run["permission"].string.map(permissionWords)),
        ]
        var groups: [(source: String, parts: [String])] = []
        for (field, text) in values {
            guard let text, !text.isEmpty else { continue }
            let source = sources[field].string ?? "default"
            if let index = groups.firstIndex(where: { $0.source == source }) { groups[index].parts.append(text) }
            else { groups.append((source, [text])) }
        }
        guard !groups.isEmpty else { return nil }
        return groups.map { $0.parts.joined(separator: " · ") + " · " + phrase($0.source, job: job) }.joined(separator: "; ")
    }
    static func phrase(_ source: String, job: String) -> String {
        switch source {
        case "playbook": return job.isEmpty ? "from the playbook" : "from the playbook: " + job
        case "agent": return "from its own settings"
        case "task": return "set on this task"
        default: return "from the app defaults"
        }
    }
    /// A CLI's own permission word in the app's words.
    public static func permissionWords(_ mode: String) -> String {
        switch mode {
        case "default": return "Ask first"
        case "acceptEdits", "workspace-write", "auto_edit": return "Auto edits"
        case "plan", "read-only": return "Plan only"
        case "bypassPermissions", "danger-full-access", "yolo": return "Bypass permissions"
        default: return mode
        }
    }
}
