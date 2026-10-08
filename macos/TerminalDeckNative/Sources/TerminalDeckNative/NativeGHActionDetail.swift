import SwiftUI
import TerminalDeckNativeCore

struct NativeGHActionDetail: View {
    @Bindable var model: NativeGHDetailModel
    @State private var selectedJob: CodingAIJSON?
    private var run: NativeGHItem { model.currentActionRun }
    private var runID: CodingAIJSON { model.detail["id"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text((model.detail["conclusion"].text ?? model.detail["status"].text ?? "Run").replacingOccurrences(of: "_", with: " "))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Re-run failed jobs…") { confirm("actions.rerun", action: "Re-run failed jobs", message: "Re-run the failed jobs in “\(run.title)” in \(run.repo). This may use GitHub Actions minutes.") }
                    .disabled(!model.canRerunFailedActionJobs)
                Button("Cancel run…") { confirm("actions.cancel", action: "Cancel run", message: "Stop the running jobs in “\(run.title)” in \(run.repo).") }
                    .disabled(!model.canCancelActionRun)
            }
            .controlSize(.small)
            if let branch = model.detail["head_branch"].text { NativeGHKeyValue(label: "Branch", value: branch) }
            if let sha = model.detail["head_sha"].text { NativeGHKeyValue(label: "Commit", value: String(sha.prefix(12))) }
            if let event = model.detail["event"].text { NativeGHKeyValue(label: "Started by", value: event.replacingOccurrences(of: "_", with: " ")) }
            NativeGHSection(title: "Jobs") {
                if let error = model.sectionErrors["jobs"] { NativeGHErrorNote(message: error) { Task { await model.loadSection("jobs") } } }
                else if model.loading && model.jobs.isEmpty { NativeGHListSkeleton().frame(height: 230) }
                else if model.jobs.isEmpty { NativePageNote("GitHub has not reported any jobs for this run yet.").padding(16) }
                else {
                    ForEach(Array(model.jobs.enumerated()), id: \.offset) { _, job in
                        Button { selectedJob = job } label: {
                            HStack(spacing: 8) {
                                Image(systemName: statusSymbol(job)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job["name"].text ?? "Job").font(.callout.weight(.medium))
                                    Text((job["conclusion"].text ?? job["status"].text ?? "pending").replacingOccurrences(of: "_", with: " "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedJob?["id"] == job["id"] ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).help("View job steps and logs")
                    }
                    NativeGHLoadMore(model: model, section: "jobs")
                }
            }
            if let job = selectedJob ?? model.jobs.first {
                NativeGHSection(title: job["name"].text ?? "Job") {
                    if let steps = job["steps"].array, !steps.isEmpty {
                        DisclosureGroup("Steps") {
                            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                                HStack(spacing: 8) {
                                    Image(systemName: statusSymbol(step)).foregroundStyle(.secondary)
                                    Text(step["name"].text ?? "Step").font(.callout)
                                    Spacer(minLength: 0)
                                    Text((step["conclusion"].text ?? step["status"].text ?? "pending").replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .font(.callout)
                    }
                    if let jobID = job["id"].ghInt {
                        NativeGHJobLogs(repo: model.item.repo, jobID: jobID, jobURL: job["html_url"].text)
                            .id(jobID)
                    }
                }
            }
        }
        .onChange(of: model.revision) { _, _ in
            if let previous = selectedJob, let updated = model.jobs.first(where: { $0["id"] == previous["id"] }) { selectedJob = updated }
        }
    }

    private func confirm(_ operation: String, action: String, message: String) {
        model.draft = NativeGHWriteDraft(title: action, action: action, operation: operation,
                                        arguments: ["repo": .string(run.repo), "runId": runID], fields: [], message: message)
    }

    private func statusSymbol(_ value: CodingAIJSON) -> String {
        switch value["conclusion"].text ?? value["status"].text ?? "" {
        case "success": "checkmark.circle"
        case "failure", "timed_out", "action_required": "xmark.circle"
        case "cancelled", "skipped", "neutral": "minus.circle"
        default: "clock"
        }
    }
}
