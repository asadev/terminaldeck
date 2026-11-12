import SwiftUI
import TerminalDeckNativeCore

/// The preview and MCP use the same four backend operations. No AI is started.
struct ROUTINESSkillVersionsView: View {
    let skill: String
    let model: ROUTINESSkillsStore
    @State private var state = NativeRPCValue.object([])
    @State private var selected = ""
    @State private var label = ""
    @State private var pending = false
    @State private var loading = true
    @State private var problem: String?
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved versions").font(.headline)
            if loading { ProgressView("Reading version history…").controlSize(.small) }
            else {
                Text(state["dirty"].bool == false ? "Working files match the adopted version." : "Working files have edits or no adopted baseline.").font(.caption).foregroundStyle(.secondary)
                Text("Saving keeps every file. Adoption changes files for future runs; it does not change an AI already running.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    NativeSessionTextField("Version name", text: $label)
                    NativeSessionButton("Save version") { perform("skills:version_save", extra: ["label": label, "expectedDigest": state["currentDigest"].string ?? ""]) }.disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pending)
                }
                let versions = state["versions"].elements ?? []
                if versions.isEmpty { Text("No saved versions yet.").font(.callout).foregroundStyle(.secondary) }
                else {
                    Picker("Version", selection: $selected) {
                        ForEach(Array(versions.enumerated()), id: \.offset) { _, row in
                            Text((row["label"].string ?? "Version") + (row["id"] == state["adoptedVersion"] ? " · adopted" : "")).tag(row["id"].string ?? "")
                        }
                    }.disabled(pending)
                    if let row = versions.first(where: { $0["id"].string == selected }) {
                        Text("\((row["files"].elements ?? []).count) entries · \(String((row["digest"].string ?? "").prefix(12)))").font(.caption.monospaced()).textSelection(.enabled)
                        if let at = row["createdAt"].number { Text("Saved " + Date(timeIntervalSince1970: at / 1000).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        DisclosureGroup("Saved files") {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array((row["files"].elements ?? []).enumerated()), id: \.offset) { _, file in
                                        Text((file["path"].string ?? "") + (file["directory"].bool == true ? "/" : " · \(Int(file["bytes"].number ?? 0)) bytes" + (file["executable"].bool == true ? " · executable" : ""))).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 120)
                        }
                        HStack {
                            NativeSessionButton("Package check") { perform("skills:version_check", extra: ["version": selected]) }
                            NativeSessionButton("Use this version") { perform("skills:version_adopt", extra: ["version": selected, "expectedDigest": state["currentDigest"].string ?? ""]) }
                        }.disabled(pending)
                        let checks = (state["checks"].elements ?? []).filter { $0["version"].string == selected }
                        if let check = checks.first {
                            Text(check["passed"].bool == true ? "Package check passed · " + String((check["digest"].string ?? "").prefix(12)) : "Package check failed").font(.callout)
                            ForEach((check["findings"].elements ?? []).compactMap(\.string), id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                        }
                        Text("Package checks validate saved bytes, file modes and command names. They do not test AI behavior. Older versions use the same adoption button to roll back; current edits are checkpointed first.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if state["recoveryPending"].bool == true { Text("An interrupted adoption needs recovery. Refresh, then use a version to recover the old files first; refresh again if its digest changed.").font(.caption).foregroundStyle(.orange) }
                HStack { NativeSessionButton("Refresh") { Task { await refresh() } }.disabled(pending); if pending { ProgressView().controlSize(.small); Text("Saving…").font(.caption) } }
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.task { await refresh() }
    }
    private func refresh() async {
        do {
            state = try await model.versionCall("skills:versions", args: ["skill": skill])
            let rows = state["versions"].elements ?? []
            if !rows.contains(where: { $0["id"].string == selected }) { selected = rows.first?["id"].string ?? "" }
            problem = nil
        } catch { problem = error.localizedDescription }
        loading = false
    }
    private func perform(_ channel: String, extra: [String: Any]) {
        guard !pending else { return }; pending = true; problem = nil; message = nil
        Task {
            defer { pending = false }
            do {
                let result = try await model.versionCall(channel, args: extra.merging(["skill": skill]) { _, value in value })
                if let checkpoint = result["checkpointVersion"].string { message = "Previous working files saved as checkpoint " + String(checkpoint.prefix(8)) + "." }
                else { message = channel == "skills:version_check" ? "Package check saved for this exact version." : "Saved." }
                if channel == "skills:version_save" { selected = result["version"]["id"].string ?? selected; label = "" }
                await refresh(); await model.refreshPreview(skill)
            } catch { problem = error.localizedDescription }
        }
    }
}
