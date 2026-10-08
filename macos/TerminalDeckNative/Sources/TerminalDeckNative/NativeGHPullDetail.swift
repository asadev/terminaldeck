import SwiftUI
import TerminalDeckNativeCore

struct NativeGHPullDetail: View {
    @Bindable var model: NativeGHDetailModel
    let open: (NativeGHItem) -> Void
    @State private var tab = "description"

    private var merged: Bool { model.detail["merged"].isTrue || model.detail["merged_at"].text != nil }
    private var isOpen: Bool { model.detail["state"].text == "open" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(merged ? "Merged" : (model.detail["draft"].isTrue ? "Draft" : model.detail["state"].text?.capitalized ?? "Pull request"))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: .capsule)
                Spacer(minLength: 0)
                Button("Comment") { model.comment() }
                Menu("Review") {
                    Button("Approve…") { model.review("APPROVE") }
                    Button("Request changes…") { model.review("REQUEST_CHANGES") }
                }
                .disabled(!isOpen || merged)
                Menu("More") {
                    Button(isOpen ? "Close pull request…" : "Reopen pull request…") { model.changeState() }.disabled(merged)
                }
                if isOpen && !merged { Button("Merge…", action: merge).disabled(model.detail["draft"].isTrue) }
            }
            .controlSize(.small)
            .disabled(model.loading)
            if let head = model.detail["head"]["ref"].text, let base = model.detail["base"]["ref"].text {
                Label("\(head) → \(base)", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    NativeGHTabButton(title: "Description", selected: tab == "description") { tab = "description" }
                    NativeGHTabButton(title: "Files\(model.files.isEmpty ? "" : " \(model.files.count)")", selected: tab == "files") { tab = "files" }
                    NativeGHTabButton(title: "Checks", selected: tab == "checks") { tab = "checks" }
                    NativeGHTabButton(title: "Comments", selected: tab == "comments") { tab = "comments" }
                }
            }
            .scrollIndicators(.hidden)
            switch tab {
            case "files": NativeGHPullFiles(model: model)
            case "checks": checks
            case "comments":
                NativeGHComments(comments: model.comments, loading: model.loading, error: model.sectionErrors["comments"], retry: reload)
                NativeGHLoadMore(model: model, section: "comments")
            default:
                if model.loading && model.detail["body"].isNull {
                    NativeGHListSkeleton().frame(height: 200)
                } else {
                    NativeGHBody(text: model.detail["body"].text)
                    if let count = model.detail["commits"].ghInt {
                        Text("\(count) commit\(count == 1 ? "" : "s") · \(model.detail["changed_files"].ghInt ?? model.files.count) changed files")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 20) {
            NativeGHSection(title: "Checks") {
                if let error = model.sectionErrors["checks"] { NativeGHErrorNote(message: error, retry: reload) }
                else if model.loading && model.checks.isEmpty { NativeGHListSkeleton().frame(height: 180) }
                else if model.checks.isEmpty { NativePageNote("No checks reported for this pull request.").padding(16) }
                else {
                    ForEach(Array(model.checks.enumerated()), id: \.offset) { _, check in
                        NativeGHCheckRow(check: check)
                    }
                    NativeGHLoadMore(model: model, section: "checks")
                }
            }
            if let sha = model.detail["head"]["sha"].text {
                NativeGHPRRuns(repo: model.item.repo, sha: sha, open: open)
            }
        }
    }

    private func reload() { Task { await model.load() } }

    private func merge() {
        var args = model.arguments
        if let sha = model.detail["head"]["sha"].text { args["expectedHeadSHA"] = .string(sha) }
        model.draft = NativeGHWriteDraft(title: "Merge pull request", action: "Merge pull request", operation: "pulls.merge", arguments: args,
                                        fields: [.choice("mergeMethod", "Merge method", choices: [("merge", "Merge commit"), ("squash", "Squash commits"), ("rebase", "Rebase commits")], value: "squash")],
                                        message: "Merge “\(model.detail["title"].text ?? model.item.title)” into \(model.detail["base"]["ref"].text ?? "the target branch") in \(model.item.repo). GitHub checks your permission and the repository’s merge rules.")
    }
}

private struct NativeGHCheckRow: View {
    let check: CodingAIJSON
    @State private var expanded = false
    private var outcome: String { check["conclusion"].text ?? check["state"].text ?? check["status"].text ?? "pending" }
    private var symbol: String {
        switch outcome {
        case "success": "checkmark.circle"
        case "failure", "error", "timed_out": "xmark.circle"
        case "cancelled", "skipped", "neutral": "minus.circle"
        default: "clock"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(check["name"].text ?? check["context"].text ?? "Check").font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Text(outcome.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
            }
            if let description = check["description"].text { NativeGHBody(text: description) }
            if let summary = check["output"]["summary"].text ?? check["output"]["text"].text {
                DisclosureGroup("Details", isExpanded: $expanded) { NativeGHBody(text: summary).padding(.top, 8) }
                    .font(.callout)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }
}

private struct NativeGHPRRuns: View {
    let repo: String
    let sha: String
    let open: (NativeGHItem) -> Void
    @State private var items: [NativeGHItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var page = 1
    @State private var hasMore = false
    var body: some View {
        NativeGHSection(title: "Actions for this commit") {
            if let error { NativeGHErrorNote(message: error) { Task { await load() } } }
            else if loading { NativeGHListSkeleton().frame(height: 180) }
            else if items.isEmpty { NativePageNote("No Actions runs for this commit.").padding(16) }
            else {
                ForEach(items) { item in
                    Button { open(item) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.callout.weight(.medium))
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                if hasMore {
                    Button(loading ? "Loading more…" : "Load more runs") { Task { await load(more: true) } }
                        .disabled(loading).controlSize(.small)
                }
            }
        }
        .task(id: sha) { await load() }
    }
    private func load(more: Bool = false) async {
        loading = true
        error = nil
        do {
            let next = more ? page + 1 : 1
            let answer = try await NativeGHBridge.call("actions.runs", ["repo": .string(repo), "headSha": .string(sha), "page": .number(Double(next)), "perPage": .number(50)])
            let incoming = answer.ghItems.map { NativeGHItem(raw: $0, area: .actions, fallbackRepo: repo) }
            if more { let known = Set(items.map(\.id)); items += incoming.filter { !known.contains($0.id) } }
            else { items = incoming }
            page = next
            hasMore = answer["hasMore"].isTrue
        } catch { self.error = CodingAIErrorText.from(error, fallback: "Could not load Actions for this commit. Try again.") }
        loading = false
    }
}

private struct NativeGHPullFiles: View {
    @Bindable var model: NativeGHDetailModel
    @State private var selectedPath: String?
    private var selected: CodingAIJSON? { model.files.first { $0["filename"].text == selectedPath } ?? model.files.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.sectionErrors["files"] {
                NativeGHErrorNote(message: error) { Task { await model.load() } }
            } else if model.loading && model.files.isEmpty {
                NativeGHListSkeleton().frame(height: 220)
            } else if model.files.isEmpty {
                NativePageNote("No changed files reported.").padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.files.enumerated()), id: \.offset) { _, file in
                            let path = file["filename"].text ?? "File"
                            Button { selectedPath = path } label: {
                                HStack(spacing: 8) {
                                    Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    Text("+\(file["additions"].ghInt ?? 0) −\(file["deletions"].ghInt ?? 0)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(selected?["filename"].text == path ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
                            }
                            .buttonStyle(.plain).help(path)
                        }
                    }
                }
                .frame(maxHeight: 160)
                NativeGHLoadMore(model: model, section: "files")
                if let file = selected {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(file["filename"].text ?? "File").font(.caption.monospaced().weight(.semibold)).textSelection(.enabled)
                        Text(file["status"].text?.capitalized ?? "Changed").font(.caption).foregroundStyle(.secondary)
                        if let previous = file["previous_filename"].text {
                            Text("Previously \(previous)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if let patch = file["patch"].text {
                            NativeGHDiff(patch: patch) { line, side in
                                model.lineComment(path: file["filename"].text ?? "", line: line, side: side)
                            }
                            .frame(height: 370)
                            Text("Click the comment button beside a line to review that change.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            NativePageNote("GitHub has no text diff for this file. It may be binary or too large.").padding(20)
                        }
                    }
                }
            }
        }
    }
}
