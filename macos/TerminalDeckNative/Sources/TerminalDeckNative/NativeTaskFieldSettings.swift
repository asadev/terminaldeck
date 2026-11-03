import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// MARK: - Type-specific settings

struct FieldCaption: View {
    let text: String
    var required = false

    var body: some View {
        (Text(text) + (required ? Text(" *").foregroundColor(TaskTone.input) : Text("")))
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }
}

struct OptionsEditor: View {
    @Binding var options: [FieldOption]
    let noun: String
    @State private var adding = ""
    @State private var palette: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldCaption(text: noun == "label" ? "Labels" : "Options")
            ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Button { palette = palette == o.id ? nil : o.id } label: { Circle().fill(FieldPaint.hex(o.color)).frame(width: 16, height: 16) }
                            .buttonStyle(.plain).accessibilityLabel("Colour of \(o.label)")
                        TextField("", text: Binding(get: { o.label }, set: { new in
                            options = options.map { $0.id == o.id ? FieldOption(id: $0.id, label: String(new.prefix(60)), color: $0.color) : $0 }
                        }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(noun) \(i + 1)")
                        Button { options.removeAll { $0.id == o.id } } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Remove \(o.label)")
                    }
                    if palette == o.id {
                        HStack(spacing: 4) {
                            ForEach(TaskFields.colors, id: \.self) { c in
                                Button {
                                    options = options.map { $0.id == o.id ? FieldOption(id: $0.id, label: $0.label, color: c) : $0 }
                                    palette = nil
                                } label: {
                                    Circle().fill(FieldPaint.hex(c)).frame(width: 20, height: 20)
                                        .overlay { if o.color == c { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                                }
                                .buttonStyle(.plain).accessibilityLabel(c)
                                .accessibilityAddTraits(o.color == c ? .isSelected : [])
                            }
                        }
                        .padding(.leading, 22)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Colours for \(o.label)")
                    }
                }
            }
            HStack(spacing: 6) {
                Circle().fill(FieldPaint.hex(TaskFields.colors[options.count % TaskFields.colors.count])).opacity(0.5).frame(width: 16, height: 16)
                TextField("Add \(noun)…", text: Binding(get: { adding }, set: { adding = String($0.prefix(60)) }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityLabel("New \(noun)")
            }
        }
        .onDisappear(perform: add)
    }

    private func add() {
        let label = adding.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !label.isEmpty, !options.contains(where: { TaskFields.sameLabel($0.label, label) }) else { return }
        options.append(FieldOption(id: String(TaskFields.newKey().prefix(36)), label: label, color: TaskFields.colors[options.count % TaskFields.colors.count]))
        adding = ""
    }
}

/// Everything a type can be told, before and after it is created ("Edit options").
struct FieldConfigForm: View {
    let kind: FieldKind
    @Binding var config: FieldConfig
    let siblings: [TaskField]
    var selfId: String?
    var team: [CrmPerson] = []

    private static let decimals = Array(0...6)

    var body: some View {
        switch kind {
        case .dropdown, .labels:
            OptionsEditor(options: Binding(get: { config.options ?? [] }, set: { config.options = $0 }), noun: kind == .labels ? "label" : "option")
        case .number:
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "Decimals")
                decimalsPicker("Decimals", Self.decimals)
            }
        case .money:
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Currency")
                    Picker("Currency", selection: Binding(get: { config.currency ?? TaskFields.defaultCurrency }, set: { config.currency = $0 })) {
                        ForEach(TaskFields.currencies, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Decimals")
                    decimalsPicker("Decimals", Array(0...4))
                }
            }
        case .date:
            Toggle("Include time", isOn: Binding(get: { config.includeTime == true }, set: { config.includeTime = $0 })).toggleStyle(.checkbox)
        case .rating:
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Out of")
                    Picker("Rating maximum", selection: Binding(get: { config.max ?? 5 }, set: { config.max = $0 })) {
                        ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Icon")
                    HStack(spacing: 4) {
                        ForEach(RatingIcon.allCases, id: \.self) { r in
                            let on = (config.icon ?? .star) == r
                            Button { config.icon = r } label: {
                                Text(r.glyph).foregroundStyle(Color.orange).frame(width: 32, height: 32)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(r.label)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Rating icon")
                }
            }
        case .progressManual:
            HStack(spacing: 8) {
                numberBox("Start", Binding(get: { config.start ?? 0 }, set: { config.start = $0 }))
                numberBox("End", Binding(get: { config.end ?? 100 }, set: { config.end = $0 }))
            }
        case .progressAuto:
            VStack(alignment: .leading, spacing: 6) {
                FieldCaption(text: "Count")
                Toggle("Subtasks", isOn: Binding(get: { config.subtasks != false }, set: { config.subtasks = $0 })).toggleStyle(.checkbox)
                Toggle("Checklist items", isOn: Binding(get: { config.checklists != false }, set: { config.checklists = $0 })).toggleStyle(.checkbox)
            }
        case .formula:
            FormulaSettings(config: $config, siblings: siblings, selfId: selfId)
        case .relationship:
            let areas = config.areas ?? []
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "Link to")
                HStack(spacing: 4) {
                    ForEach(TaskFields.tagAreas, id: \.key) { a in
                        let on = areas.contains(a.key)
                        FieldChipToggle(title: a.label, on: on) { config.areas = on ? areas.filter { $0 != a.key } : areas + [a.key] }
                    }
                }
                Text(areas.isEmpty ? "None picked = anything in the CRM." : "Only these.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        case .button:
            ButtonSettings(config: $config, siblings: siblings, selfId: selfId, team: team)
        default:
            EmptyView()
        }
    }

    private func decimalsPicker(_ label: String, _ values: [Int]) -> some View {
        Picker(label, selection: Binding(get: { config.decimals ?? 2 }, set: { config.decimals = $0 })) {
            ForEach(values, id: \.self) { Text(TaskFields.decimalsLabel($0)).tag($0) }
        }
        .labelsHidden()
    }

    private func numberBox(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldCaption(text: label)
            TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }
    }
}

struct FormulaSettings: View {
    @Binding var config: FieldConfig
    let siblings: [TaskField]
    let selfId: String?

    var body: some View {
        let others = siblings.filter { $0.id != selfId }
        let numeric = others.filter { [.number, .money, .rating, .progressManual, .checkbox].contains($0.kind) }
        let expression = config.expression ?? ""
        let preview: FieldRes<Double>? = expression.isEmpty ? nil : TaskFields.computeFormula(expression, others)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "Formula")
                TextField("{Price} * {Quantity}", text: Binding(get: { expression }, set: { config.expression = String($0.prefix(500)) }), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel("Formula")
                Text("Fields in {braces} · + − * / % ( ) · round, min, max, abs, floor, ceil").font(.system(size: 11)).foregroundStyle(.tertiary)
                if !numeric.isEmpty {
                    TasksFlow(spacing: 4, lineSpacing: 4) {
                        ForEach(numeric) { s in
                            Button {
                                let base = expression.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                                let next = "\(base) {\(s.label)}"
                                config.expression = next.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
                            } label: {
                                Text("{\(s.label)}").font(.system(size: 11)).padding(.horizontal, 6).frame(height: 24)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                switch preview {
                case .success(let n)?:
                    Text("= \(TaskFields.formatNumber(n, config.decimals ?? 2))").font(.caption).foregroundStyle(.secondary)
                case .failure(let f)?:
                    Text(f.error).font(.caption).foregroundStyle(TaskTone.input)
                case nil:
                    EmptyView()
                }
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Show as")
                    Picker("Show formula as", selection: Binding(get: { config.currency ?? "" }, set: { config.currency = $0.isEmpty ? nil : $0 })) {
                        Text("Number").tag("")
                        ForEach(TaskFields.currencies, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Decimals")
                    Picker("Formula decimals", selection: Binding(get: { config.decimals ?? 2 }, set: { config.decimals = $0 })) {
                        ForEach(0...6, id: \.self) { Text(TaskFields.decimalsLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                }
            }
        }
    }
}

struct ButtonSettings: View {
    @Binding var config: FieldConfig
    let siblings: [TaskField]
    let selfId: String?
    let team: [CrmPerson]

    var body: some View {
        let action = config.action ?? .status("Done")
        let targets = siblings.filter { $0.id != selfId && TaskFields.buttonTargetKinds.contains($0.kind) }
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "Button label")
                TextField("Mark done", text: Binding(get: { config.label ?? "" }, set: { config.label = String($0.prefix(40)) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Button label")
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "Colour")
                HStack(spacing: 4) {
                    ForEach(TaskFields.colors, id: \.self) { c in
                        Button { config.color = c } label: {
                            Circle().fill(FieldPaint.hex(c)).frame(width: 20, height: 20)
                                .overlay { if config.color == c { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                        }
                        .buttonStyle(.plain).accessibilityLabel(c)
                        .accessibilityAddTraits(config.color == c ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Button colour")
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "When pressed")
                Picker("Button action", selection: Binding(get: { action.type }, set: { type in
                    switch type {
                    case "status": config.action = .status("Done")
                    case "comment": config.action = .comment("")
                    default: config.action = .field(fieldId: targets.first?.id ?? "", value: .null)
                    }
                })) {
                    Text("Set the status").tag("status")
                    Text("Set a field").tag("field")
                    Text("Add a comment").tag("comment")
                }
                .labelsHidden()
            }
            switch action {
            case .status(let status):
                Picker("Status the button sets", selection: Binding(get: { status }, set: { config.action = .status($0) })) {
                    ForEach(TaskFields.buttonStatuses, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            case .comment(let body):
                TextField("Comment to add…", text: Binding(get: { body }, set: { config.action = .comment(String($0.prefix(2000))) }), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Comment the button adds")
            case .field(let fieldId, let value):
                if targets.isEmpty {
                    Text("Add a Text, Number, Money, Date, Checkbox, Dropdown, Labels, Rating, Progress, Website, Email, Phone or Location field first.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Field the button sets", selection: Binding(get: { fieldId }, set: { config.action = .field(fieldId: $0, value: .null) })) {
                        Text("Choose a field…").tag("")
                        ForEach(targets) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                    if let target = targets.first(where: { $0.id == fieldId }) {
                        let shadow = TaskField(id: "btn-target-\(target.id)", taskId: "", label: "\(target.label) value", kind: target.kind,
                                               config: target.config, value: value)
                        FieldValueEditor(field: shadow, ctx: .detached(team: team)) { raw in
                            let n = TaskFields.normaliseValue(target.kind, target.config, raw, ctx: ValueCtx(userId: "", now: ""))
                            config.action = .field(fieldId: target.id, value: (try? n.get()) ?? raw)
                        }
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    }
                }
            }
        }
    }
}
