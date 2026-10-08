import SwiftUI
import TerminalDeckNativeCore

struct NativeGHDetailScreen: View {
    let item: NativeGHItem
    let cwd: String
    let completed: (String) -> Void
    let open: (NativeGHItem) -> Void
    @State private var model: NativeGHDetailModel

    init(item: NativeGHItem, cwd: String, completed: @escaping (String) -> Void, open: @escaping (NativeGHItem) -> Void) {
        self.item = item
        self.cwd = cwd
        self.completed = completed
        self.open = open
        _model = State(initialValue: NativeGHDetailModel(item: item))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = model.notice {
                    Label(message, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.error { NativeGHErrorNote(message: error) { Task { await model.load() } } }
                if model.loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading details…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                switch item.area {
                case .pulls: NativeGHPullDetail(model: model, open: open)
                case .issues: NativeGHIssueDetail(model: model)
                case .repos: NativeGHRepositoryDetail(model: model, cwd: cwd, use: { open(item) })
                case .actions: NativeGHActionDetail(model: model)
                case .inbox: inbox
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.load() }
        .sheet(item: $model.draft) { draft in
            NativeGHWriteSheet(draft: draft) { text in model.completed(text); completed(text) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(item.area == .actions ? model.currentActionRun.title : model.detail["title"].text ?? item.title)
                    .font(.title3.weight(.semibold)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh details").disabled(model.loading)
            }
            Text(item.area == .actions ? model.currentActionRun.subtitle : item.subtitle).font(.caption).foregroundStyle(.secondary)
            if let url = model.detail["html_url"].text ?? item.url {
                NativeGHSecondaryLink(url: url)
            }
        }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativeGHKeyValue(label: "Reason", value: (item.raw["reason"].text ?? "Notification").replacingOccurrences(of: "_", with: " "))
            NativeGHKeyValue(label: "Repository", value: item.repo)
            NativeGHKeyValue(label: "Updated", value: NativeGHDate.text(item.raw["updated_at"].text))
            HStack(spacing: 8) {
                if let target = notificationTarget {
                    Button("Open \(target.area == .pulls ? "pull request" : target.area == .issues ? "issue" : "run")") { open(target) }
                }
                if item.raw["unread"].isTrue {
                    Button("Mark as read") {
                        model.draft = NativeGHWriteDraft(title: "Mark notification as read", action: "Mark as read", operation: "notifications.read", arguments: ["threadId": item.raw["id"]], fields: [], message: "Mark “\(item.title)” as read in your GitHub inbox.")
                    }
                } else { Text("Read").font(.callout).foregroundStyle(.secondary) }
            }
            if notificationTarget == nil {
                Text("This notification has no pull request, issue, or run that GitHub lets the app open here.")
                    .font(.callout).foregroundStyle(.secondary)
                if let url = notificationWebURL { NativeGHSecondaryLink(url: url) }
            }
        }
    }

    private var notificationTarget: NativeGHItem? {
        let kind = item.raw["subject"]["type"].text ?? ""
        let area: NativeGHArea
        switch kind {
        case "PullRequest": area = .pulls
        case "Issue": area = .issues
        case "CheckSuite", "WorkflowRun": area = .actions
        default: return nil
        }
        guard let url = item.raw["subject"]["url"].text,
              let number = Int(URL(string: url)?.lastPathComponent ?? ""),
              !item.repo.isEmpty else { return nil }
        if area == .actions && !url.contains("/actions/runs/") { return nil }
        let webPath = area == .pulls ? "pull" : area == .issues ? "issues" : "actions/runs"
        var raw: [String: CodingAIJSON] = ["title": .string(item.title), "repository": .object(["full_name": .string(item.repo)]),
                                           "html_url": .string("https://github.com/\(item.repo)/\(webPath)/\(number)")]
        raw[area == .actions ? "id" : "number"] = .number(Double(number))
        return NativeGHItem(raw: .object(raw), area: area, fallbackRepo: item.repo)
    }

    private var notificationWebURL: String? {
        guard let url = item.raw["subject"]["url"].text, url.hasPrefix("https://api.github.com/repos/") else { return nil }
        return url.replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
            .replacingOccurrences(of: "/pulls/", with: "/pull/")
    }
}

struct NativeGHSecondaryLink: View {
    let url: String
    var body: some View {
        Button("Open on GitHub ↗") { GitHubScreenModel.open(url) }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            .help("Open this item on GitHub")
            .contextMenu { Button("Copy link") { DeckProject.copy(url) } }
    }
}

struct NativeGHSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout.weight(.semibold)).accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeGHBody: View {
    let text: String?
    var empty = "No description."
    var body: some View {
        Group {
            if let text, !text.isEmpty {
                Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                    .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else { Text(empty).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeGHComments: View {
    let comments: [CodingAIJSON]
    let loading: Bool
    let error: String?
    let retry: () -> Void
    var body: some View {
        if let error { NativeGHErrorNote(message: error, retry: retry) }
        else if loading && comments.isEmpty { NativeGHListSkeleton().frame(height: 230) }
        else if comments.isEmpty { NativePageNote("No comments yet.").padding(.vertical, 24) }
        else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(comment["user"]["login"].text ?? comment["author"]["login"].text ?? "GitHub user").fontWeight(.medium)
                            Text(NativeGHDate.text(comment["created_at"].text ?? comment["submitted_at"].text)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            if let state = comment["state"].text { Text(state.replacingOccurrences(of: "_", with: " ").lowercased()).foregroundStyle(.secondary) }
                        }
                        .font(.caption)
                        if let path = comment["path"].text {
                            Text("\(path)\(comment["line"].ghInt.map { ":\($0)" } ?? "")")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        NativeGHBody(text: comment["body"].text, empty: "No comment text.")
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                }
            }
        }
    }
}

struct NativeGHLoadMore: View {
    @Bindable var model: NativeGHDetailModel
    let section: String
    var branch: String? = nil
    var body: some View {
        if model.sectionHasMore[section] == true {
            Button {
                Task { await model.loadSection(section, more: true, branch: branch) }
            } label: {
                HStack(spacing: 8) {
                    if model.loadingSections.contains(section) { ProgressView().controlSize(.small) }
                    Text(model.loadingSections.contains(section) ? "Loading more…" : "Load more \(section)")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(model.loading || model.loadingSections.contains(section))
            .controlSize(.small)
        }
    }
}

enum NativeGHDate {
    static func text(_ value: String?) -> String {
        guard let value else { return "" }
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
