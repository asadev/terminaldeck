import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// MARK: - The section

struct TaskFieldsSection: View {
    let model: TaskDetailModel
    var onNavigate: (String) -> Void = { _ in }
    @State private var store: FieldsStore?

    var body: some View {
        Group {
            if let store, store.taskId == model.taskId, store.ready {
                FieldsBody(model: model, store: store, onNavigate: onNavigate)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fields").font(.system(size: 13)).foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)).frame(width: 192, height: 28)
                        .accessibilityLabel("Loading fields")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: model.taskId) {
            let next = FieldsStore(model: model)
            store = next
            await next.load()
        }
    }
}

struct FieldsBody: View {
    let model: TaskDetailModel
    let store: FieldsStore
    let onNavigate: (String) -> Void
    @State private var creating = false

    var body: some View {
        let canEdit = model.canEditRow
        if canEdit || store.loadError != nil || !store.fields.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fields").font(.system(size: 13)).foregroundStyle(.secondary)
                if let error = store.loadError {
                    Text("Fields unavailable: \(error)").font(.caption).foregroundStyle(.tertiary)
                } else {
                    let ctx = context(readOnly: !canEdit)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.fields.enumerated()), id: \.element.id) { i, f in
                            FieldRow(field: f, ctx: ctx, first: i == 0, last: i == store.fields.count - 1, error: store.errors[f.id], store: store)
                        }
                    }
                    if let e = store.sectionErr {
                        Text(e).font(.caption).foregroundStyle(TaskTone.input).accessibilityAddTraits(.isStaticText)
                    }
                    if canEdit {
                        Button { creating.toggle() } label: {
                            Label("Create new field", systemImage: "plus")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .popover(isPresented: $creating, arrowEdge: .bottom) {
                            CreateFieldPanel(siblings: store.fields, team: model.team, onCancel: { creating = false }) { label, kind, config in
                                let err = await store.create(label: label, kind: kind, config: config)
                                if err == nil { creating = false }
                                return err
                            }
                            .frame(width: 320)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func context(readOnly: Bool) -> FieldCtx {
        var ctx = FieldCtx(taskId: store.taskId, fields: store.fields, people: store.people, team: model.team, auto: store.auto,
                           viewerId: store.viewerId, readOnly: readOnly, busy: store.busy, model: model)
        let store = store
        let model = model
        let onNavigate = onNavigate
        ctx.rememberPerson = { store.remember($0) }
        ctx.onVote = { f in Task { await store.vote(f) } }
        ctx.onPress = { f in Task { await store.press(f) } }
        ctx.onFiles = { f, urls in Task { await store.upload(f, urls) } }
        ctx.onOpen = { href in
            if href.hasPrefix("/tasks?task="), let id = String(href.dropFirst("/tasks?task=".count)).removingPercentEncoding {
                onNavigate(id)
            } else if href.hasPrefix("/files/") {
                let parts = href.dropFirst("/files/".count).split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
                if parts.count == 2 { Task { _ = await model.call("openTaskFile", [parts[0], parts[1]]) } }
            }
        }
        return ctx
    }
}
