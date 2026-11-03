import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// MARK: - The value editor, per kind

struct FieldValueEditor: View {
    let field: TaskField
    let ctx: FieldCtx
    let onCommit: (CrmValue) -> Void

    var body: some View {
        let ro = ctx.readOnly
        let v = field.value
        let str = v.string ?? ""
        switch field.kind {
        case .text:
            FieldTextCell(value: str, onCommit: { onCommit(.string($0)) }, readOnly: ro, label: field.label)
        case .longText:
            FieldTextCell(value: str, onCommit: { onCommit(.string($0)) }, readOnly: ro, multiline: true, placeholder: "Write something…", label: field.label)
        case .number:
            let d = field.config.decimals ?? 2
            FieldTextCell(value: v.number.map(TaskFields.js) ?? "", display: v.number.map { TaskFields.formatNumber($0, d) } ?? "",
                          onCommit: { onCommit(.string($0)) }, readOnly: ro, label: field.label)
        case .money:
            let d = field.config.decimals ?? 2
            FieldTextCell(value: v.number.map(TaskFields.js) ?? "", display: v.number.map { TaskFields.formatNumber($0, d, fixed: true) } ?? "",
                          onCommit: { onCommit(.string($0)) }, readOnly: ro, label: field.label, prefix: field.config.currency ?? TaskFields.defaultCurrency)
        case .website, .email, .phone:
            ContactEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .location:
            HStack(spacing: 0) {
                FieldTextCell(value: v["text"]?.string ?? "", onCommit: { onCommit(.string($0)) }, readOnly: ro, placeholder: "Address or lat, lng", label: field.label)
                if v.object != nil { LinkOut(url: URL(string: TaskFields.mapHref(v)), label: "Open in Maps") }
            }
        case .checkbox:
            Toggle(field.label, isOn: Binding(get: { v == .bool(true) }, set: { onCommit(.bool($0)) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(ro)
                .padding(.horizontal, 8).frame(height: 28)
        case .date:
            DateEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .dropdown:
            DropdownEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .labels:
            LabelsEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .rating:
            RatingEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .people:
            PeopleEditor(field: field, ctx: ctx, onCommit: onCommit)
        case .relationship:
            RelationshipEditor(field: field, ctx: ctx, onCommit: onCommit)
        case .tasks:
            TasksEditor(field: field, ctx: ctx, onCommit: onCommit)
        case .files:
            FilesEditor(field: field, ctx: ctx, onCommit: onCommit)
        case .signature:
            SignatureEditor(field: field, ctx: ctx, onCommit: onCommit)
        case .progressManual:
            ProgressManualEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .progressAuto:
            if ctx.taskId == nil {
                Text("Counted from subtasks and checklists once the task is saved").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 8)
            } else {
                let p = TaskFields.autoProgress(field.config, ctx.auto)
                HStack(spacing: 0) {
                    ProgressBarField(percent: p.percent, label: field.label)
                    Text("\(p.done)/\(p.total)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).padding(.trailing, 8)
                }
                .help("\(p.done) of \(p.total) done")
            }
        case .formula:
            FormulaValue(field: field, ctx: ctx)
        case .voting:
            VotingButton(field: field, ctx: ctx)
        case .button:
            PressButton(field: field, ctx: ctx)
        }
    }
}

struct ContactEditor: View {
    let field: TaskField
    let readOnly: Bool
    let onCommit: (CrmValue) -> Void

    var body: some View {
        let str = field.value.string ?? ""
        let url: URL? = str.isEmpty ? nil : field.kind == .website ? URL(string: str)
            : field.kind == .email ? URL(string: "mailto:\(str)") : URL(string: "tel:\(str.filter { $0.isNumber || $0 == "+" })")
        let placeholder = field.kind == .website ? "https://" : field.kind == .email ? "name@example.com" : "+971 50 000 0000"
        let linkLabel = field.kind == .website ? "Open link" : field.kind == .email ? "Send email" : "Call"
        HStack(spacing: 0) {
            FieldTextCell(value: str, onCommit: { onCommit(.string($0)) }, readOnly: readOnly, placeholder: placeholder, label: field.label)
            if !str.isEmpty { LinkOut(url: url, label: linkLabel) }
        }
    }
}

struct FormulaValue: View {
    let field: TaskField
    let ctx: FieldCtx

    var body: some View {
        let others = ctx.fields.filter { $0.id != field.id }
        switch TaskFields.computeFormula(field.config.expression, others) {
        case .failure(let f):
            Text(f.error).font(.caption).foregroundStyle(TaskTone.input).lineLimit(1).padding(.horizontal, 8)
                .help(field.config.expression ?? "")
        case .success(let n):
            let d = field.config.decimals ?? 2
            Text(field.config.currency.map { TaskFields.formatMoney(n, $0, d) } ?? TaskFields.formatNumber(n, d))
                .font(.system(size: 13)).monospacedDigit().padding(.horizontal, 8)
                .help(field.config.expression ?? "")
        }
    }
}

struct VotingButton: View {
    let field: TaskField
    let ctx: FieldCtx

    var body: some View {
        let votes = Array((field.value["votes"]?.object ?? [:]).keys).sorted()
        let mine = ctx.viewerId.map { votes.contains($0) } ?? false
        let names = votes.map { id in ctx.people[id]?.name ?? (id == ctx.viewerId ? "You" : "Someone") }.joined(separator: ", ")
        Button { ctx.onVote(field) } label: {
            HStack(spacing: 6) {
                Image(systemName: mine ? "hand.thumbsup.fill" : "hand.thumbsup").font(.system(size: 12))
                Text("\(votes.count)").monospacedDigit()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(mine ? Color.accentColor : .secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(mine ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(ctx.readOnly || ctx.busy.contains(field.id))
        .help(names.isEmpty ? "No votes yet" : names)
        .accessibilityLabel("\(field.label): \(votes.count) votes")
        .accessibilityAddTraits(mine ? .isSelected : [])
        .padding(.horizontal, 6)
    }
}

struct PressButton: View {
    let field: TaskField
    let ctx: FieldCtx

    var body: some View {
        let count = Int(field.value["count"]?.number ?? 0)
        let busy = ctx.busy.contains(field.id)
        HStack(spacing: 8) {
            Button { ctx.onPress(field) } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.mini) }
                    Text(field.config.label ?? "Button")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(FieldPaint.hex(field.config.color)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(ctx.readOnly || ctx.taskId == nil || busy)
            .opacity(ctx.readOnly || ctx.taskId == nil || busy ? 0.5 : 1)
            .help(ctx.taskId == nil ? "Works once the task is created" : "")
            if count > 0 { Text("Pressed \(count)×").font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 6)
    }
}
