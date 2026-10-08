import SwiftUI
import TerminalDeckNativeCore

struct NativeGHIssueDetail: View {
    @Bindable var model: NativeGHDetailModel
    @State private var tab = "description"
    private var isOpen: Bool { model.detail["state"].text == "open" }
    private var assignees: [String] { (model.detail["assignees"].array ?? []).compactMap { $0["login"].text } }
    private var labels: [String] { (model.detail["labels"].array ?? []).compactMap { $0["name"].text ?? $0.text } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(model.detail["state"].text?.capitalized ?? "Issue")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: .capsule)
                Spacer(minLength: 0)
                Button("Comment") { model.comment() }
                Menu("More") {
                    Button("Assign…", action: assign)
                    Button("Change labels…", action: changeLabels)
                    Button(isOpen ? "Close issue…" : "Reopen issue…") { model.changeState() }
                }
            }
            .controlSize(.small).disabled(model.loading)
            NativeGHKeyValue(label: "Assigned to", value: assignees.isEmpty ? "No one" : assignees.joined(separator: ", "))
            NativeGHKeyValue(label: "Labels", value: labels.isEmpty ? "None" : labels.joined(separator: ", "))
            if let milestone = model.detail["milestone"]["title"].text { NativeGHKeyValue(label: "Milestone", value: milestone) }
            HStack(spacing: 4) {
                NativeGHTabButton(title: "Description", selected: tab == "description") { tab = "description" }
                NativeGHTabButton(title: "Comments", selected: tab == "comments") { tab = "comments" }
            }
            if tab == "description" {
                if model.loading && model.detail["body"].isNull { NativeGHListSkeleton().frame(height: 200) }
                else { NativeGHBody(text: model.detail["body"].text) }
            } else {
                NativeGHComments(comments: model.comments, loading: model.loading, error: model.sectionErrors["comments"]) { Task { await model.load() } }
                NativeGHLoadMore(model: model, section: "comments")
            }
        }
    }

    private func assign() {
        model.draft = NativeGHWriteDraft(title: "Assign issue", action: "Save assignees", operation: "issues.assign", arguments: model.arguments,
                                        fields: [.list("assignees", "Assigned GitHub names", value: assignees.joined(separator: ", "), hint: "Separate names with commas. Leave empty to unassign everyone.")],
                                        message: "Change the assignees on \(model.item.repo) #\(model.item.number).")
    }

    private func changeLabels() {
        model.draft = NativeGHWriteDraft(title: "Change issue labels", action: "Save labels", operation: "issues.labels", arguments: model.arguments,
                                        fields: [.list("labels", "Labels", value: labels.joined(separator: ", "), hint: "Use labels that already exist in this repository. Leave empty to remove all labels.")],
                                        message: "Replace the labels on \(model.item.repo) #\(model.item.number) with the list below.")
    }
}
