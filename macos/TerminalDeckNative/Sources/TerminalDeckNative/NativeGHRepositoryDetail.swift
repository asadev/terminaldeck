import SwiftUI
import TerminalDeckNativeCore

struct NativeGHRepositoryDetail: View {
    @Bindable var model: NativeGHDetailModel
    let cwd: String
    let use: () -> Void
    @State private var tab = "branches"

    private var defaultBranch: String { model.item.raw["default_branch"].text ?? "main" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativeGHBody(text: model.item.raw["description"].text, empty: "No repository description.")
            HStack(spacing: 8) {
                Text(model.item.raw["private"].isTrue ? "Private repository" : "Public repository").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Use repository", action: use)
                Button("Clone into a project…", action: clone)
                Button("New draft release…", action: release).disabled(model.item.raw["archived"].isTrue)
            }
            .controlSize(.small)
            NativeGHKeyValue(label: "Default branch", value: defaultBranch)
            if model.item.raw["archived"].isTrue {
                Text("This repository is archived. GitHub does not allow new changes until its owner unarchives it.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                NativeGHTabButton(title: "Branches", selected: tab == "branches") { tab = "branches" }
                NativeGHTabButton(title: "Recent commits", selected: tab == "commits") { tab = "commits" }
                NativeGHTabButton(title: "Releases", selected: tab == "releases") { tab = "releases" }
            }
            switch tab {
            case "commits": commits
            case "releases": releases
            default: branches
            }
        }
    }

    private var branches: some View {
        NativeGHSection(title: "Branches") {
            if let error = model.sectionErrors["branches"] { NativeGHErrorNote(message: error) { Task { await model.loadSection("branches") } } }
            else if model.loading && model.branches.isEmpty { NativeGHListSkeleton().frame(height: 230) }
            else if model.branches.isEmpty { NativePageNote("No branches reported.").padding(16) }
            else {
                ForEach(Array(model.branches.enumerated()), id: \.offset) { _, branch in
                    let name = branch["name"].text ?? "Branch"
                    Button {
                        model.commitBranch = name
                        tab = "commits"
                        Task { await model.loadSection("commits", branch: name) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                            Text(name).font(.callout)
                            if name == defaultBranch { Text("default").font(.caption).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                            if branch["protected"].isTrue { Image(systemName: "lock").foregroundStyle(.secondary).help("Protected branch") }
                            Text(String((branch["commit"]["sha"].text ?? "").prefix(7))).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).help("See commits on \(name)")
                    .disabled(model.loadingSections.contains("commits"))
                }
                NativeGHLoadMore(model: model, section: "branches")
            }
        }
    }

    private var commits: some View {
        NativeGHSection(title: "Recent commits") {
            HStack(spacing: 8) {
                if !model.branches.isEmpty {
                    Picker("Branch", selection: $model.commitBranch) {
                        Text("Default branch").tag("")
                        ForEach(Array(model.branches.enumerated()), id: \.offset) { _, branch in
                            if let name = branch["name"].text { Text(name).tag(name) }
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(maxWidth: 240)
                    .onChange(of: model.commitBranch) { _, value in Task { await model.loadSection("commits", branch: value) } }
                    .disabled(model.loading || model.loadingSections.contains("commits"))
                } else {
                    TextField("Branch (optional)", text: $model.commitBranch).textFieldStyle(.roundedBorder)
                    Button("Show") { Task { await model.loadSection("commits", branch: model.commitBranch) } }
                        .disabled(model.loading || model.loadingSections.contains("commits"))
                }
                if model.loadingSections.contains("commits") { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            if let error = model.sectionErrors["commits"] { NativeGHErrorNote(message: error) { Task { await model.loadSection("commits", branch: model.commitBranch) } } }
            else if model.loading && model.commits.isEmpty { NativeGHListSkeleton().frame(height: 230) }
            else if model.commits.isEmpty { NativePageNote("No commits reported for this branch.").padding(16) }
            else {
                ForEach(Array(model.commits.enumerated()), id: \.offset) { _, commit in
                    NativeGHCommitRow(commit: commit)
                }
                NativeGHLoadMore(model: model, section: "commits", branch: model.commitBranch)
            }
        }
    }

    private var releases: some View {
        NativeGHSection(title: "Releases") {
            if let error = model.sectionErrors["releases"] { NativeGHErrorNote(message: error) { Task { await model.loadSection("releases") } } }
            else if model.loading && model.releases.isEmpty { NativeGHListSkeleton().frame(height: 230) }
            else if model.releases.isEmpty { NativePageNote("No releases yet. Create a draft to start one.").padding(16) }
            else {
                ForEach(Array(model.releases.enumerated()), id: \.offset) { _, release in
                    NativeGHReleaseRow(release: release)
                }
                NativeGHLoadMore(model: model, section: "releases")
            }
        }
    }

    private func clone() {
        let name = model.item.repo.split(separator: "/").last.map(String.init) ?? "repository"
        model.draft = NativeGHWriteDraft(title: "Clone into a project", action: "Clone repository", operation: "repos.clone", arguments: ["repo": .string(model.item.repo)], fields: [
            .text("parentPath", "Inside folder", value: cwd, hint: "Choose an existing folder for the new project."),
            .text("directoryName", "New project folder", value: name),
            .text("branch", "Branch (optional)", value: defaultBranch, required: false)
        ], message: "Download \(model.item.repo) into a new folder and add it to Terminal Deck’s projects. Existing folders are never overwritten.")
    }

    private func release() {
        model.draft = NativeGHWriteDraft(title: "New draft release", action: "Create draft release", operation: "repos.draftRelease", arguments: ["repo": .string(model.item.repo)], fields: [
            .text("tagName", "Tag", hint: "For example, v1.0.0"), .text("name", "Release title", required: false),
            .text("targetCommitish", "Branch or commit", value: defaultBranch), .body("body", "Release notes"),
            .choice("prerelease", "Release type", choices: [("false", "Regular release"), ("true", "Pre-release")], value: "false", kind: .boolean)
        ], message: "Create an unpublished draft release in \(model.item.repo). You can review it before publishing on GitHub.")
    }
}

private struct NativeGHCommitRow: View {
    let commit: CodingAIJSON
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                NativeGHBody(text: commit["commit"]["message"].text).padding(.top, 8)
                NativeGHKeyValue(label: "Commit", value: commit["sha"].text ?? "")
                if let url = commit["html_url"].text { NativeGHSecondaryLink(url: url).padding(.top, 4) }
            } label: {
                Text((commit["commit"]["message"].text ?? "Commit").components(separatedBy: "\n").first ?? "Commit")
                    .font(.callout.weight(.medium)).lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(String((commit["sha"].text ?? "").prefix(7))).font(.caption.monospaced())
                Text(commit["author"]["login"].text ?? commit["commit"]["author"]["name"].text ?? "")
                Text(NativeGHDate.text(commit["commit"]["author"]["date"].text))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }
}

private struct NativeGHReleaseRow: View {
    let release: CodingAIJSON
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $expanded) {
                NativeGHBody(text: release["body"].text, empty: "No release notes.").padding(.top, 8)
                if let assets = release["assets"].array, !assets.isEmpty {
                    Text("Files").font(.caption.weight(.medium)).padding(.top, 8)
                    ForEach(Array(assets.enumerated()), id: \.offset) { _, asset in
                        HStack {
                            Text(asset["name"].text ?? "File").font(.caption.monospaced()).textSelection(.enabled)
                            Spacer(minLength: 0)
                            if let bytes = asset["size"].number {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let url = release["html_url"].text { NativeGHSecondaryLink(url: url).padding(.top, 8) }
            } label: {
                Text(release["name"].text ?? release["tag_name"].text ?? "Release").font(.callout.weight(.medium))
            }
            HStack(spacing: 8) {
                Text(release["tag_name"].text ?? "")
                if release["draft"].isTrue { Text("Draft") }
                if release["prerelease"].isTrue { Text("Pre-release") }
                Text(NativeGHDate.text(release["published_at"].text ?? release["created_at"].text))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }
}
