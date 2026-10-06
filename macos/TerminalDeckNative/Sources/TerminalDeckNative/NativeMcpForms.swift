import AppKit
import SwiftUI
import TerminalDeckNativeCore

// The two forms of the MCP page, drawn in SwiftUI: a tool's arguments
// (web: McpSchemaForm.tsx) and adding or editing a server (web: McpAddForm.tsx).
// The logic — what a schema becomes, what is missing, what is sent — is
// `McpSchema` / `McpAddDraft` in Core, shared with the tests.

/// What a failed call says, as the page's `readFailure` / `err.message`.
func mcpMessage(_ error: Error) -> String {
    if let overdue = error as? McpOverdue { return overdue.message }
    if let wire = error as? EngineWireError { return McpDeadline.failure(wire.description) }
    return McpDeadline.failure(error.localizedDescription)
}

struct McpOverdue: Error { let message: String }

/// One engine call, read with key order kept, that settles within `seconds` (`withDeadline`):
/// the request's own timeout, and its timing out told as the page's `Overdue` sentence.
@MainActor
func mcpInvoke(_ channel: String, _ args: [Any?], what: String, seconds: Double) async throws -> OrderedJSON {
    do {
        return try await EngineBridge.shared.invokeOrdered(channel, args, timeout: seconds)
    } catch let error as URLError where error.code == .timedOut {
        throw McpOverdue(message: McpDeadline.overdue(what, seconds: seconds))
    }
}

// MARK: - A plain text box

/// A text box for JSON and `KEY=value` lines. No smart quotes, dashes or
/// replacements: they would quietly turn what was typed into something else.
struct McpPlainEditor: NSViewRepresentable {
    @Binding var text: String
    /// Read-only boxes (Settings → Hoot's generated files) still select and copy.
    var editable = true

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.isContinuousSpellCheckingEnabled = false
            view.allowsUndo = true
            view.drawsBackground = false
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.textColor = .labelColor
            view.textContainerInset = NSSize(width: 3, height: 5)
            view.delegate = context.coordinator
            view.string = text
        }
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.isEditable != editable { view.isEditable = editable }
        if view.string != text { view.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: McpPlainEditor
        init(_ parent: McpPlainEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

/// The editor with its placeholder and frame, as the page's `<textarea>`.
struct McpTextBox: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 46
    var invalid = false
    var disabled = false

    var body: some View {
        McpPlainEditor(text: $text)
            .frame(minHeight: minHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 8)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(invalid ? Color.red : Color(nsColor: .separatorColor))
            )
            .disabled(disabled)
            .opacity(disabled ? 0.6 : 1)
    }
}

// MARK: - A tool's arguments (McpSchemaForm)

/// `McpSchemaForm`: one control per argument, or a JSON box when the schema cannot be laid out.
struct McpSchemaFormView: View {
    let schema: OrderedJSON
    @Binding var values: OrderedJSON
    /// Argument → its JSON error, as the page's `invalid`.
    @Binding var invalid: [String: String]
    var disabled = false

    var body: some View {
        let description = McpSchema.describe(schema)
        VStack(alignment: .leading, spacing: 10) {
            if let fallback = description.fallback {
                Text("\(fallback) Enter the arguments as JSON.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                McpJsonBox(value: (values.fields ?? []).isEmpty ? nil : values, placeholder: #"{ "key": "value" }"#,
                           disabled: disabled,
                           onValue: { next in values = next?.isObject == true ? next! : .object([]) },
                           onInvalid: { note("arguments", $0) })
            } else if description.fields.isEmpty {
                Text("This tool takes no arguments.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                McpObjectFields(fields: description.fields, values: values, disabled: disabled,
                                onValues: { values = $0 }, onInvalid: note)
            }
        }
    }

    private func note(_ name: String, _ message: String?) {
        guard invalid[name] != message else { return }
        invalid[name] = message
    }
}

/// `ObjectFields`.
struct McpObjectFields: View {
    let fields: [McpSchemaField]
    let values: OrderedJSON
    let disabled: Bool
    let onValues: (OrderedJSON) -> Void
    let onInvalid: (String, String?) -> Void

    var body: some View {
        ForEach(fields) { field in
            McpFieldView(field: field, value: values[field.name], disabled: disabled,
                         onValue: { next in
                             onValues(next.map { values.setting(field.name, $0) } ?? values.removing(field.name))
                         },
                         onInvalid: onInvalid)
        }
    }
}

/// `Field`: the name, a red star when required, the type word, the description, the control.
struct McpFieldView: View {
    let field: McpSchemaField
    let value: OrderedJSON?
    let disabled: Bool
    let onValue: (OrderedJSON?) -> Void
    let onInvalid: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(field.name).font(.callout.monospaced().weight(.medium))
                if field.required {
                    Text("*").foregroundStyle(.red).accessibilityLabel("required")
                }
                Text(field.typeWord).font(.caption).foregroundStyle(.secondary)
            }
            if let description = field.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control
        }
    }

    @ViewBuilder private var control: some View {
        if field.kind == .object, let nested = field.fields {
            // AnyView: a field holds fields, and an opaque type cannot contain itself.
            AnyView(
                VStack(alignment: .leading, spacing: 10) {
                    McpObjectFields(fields: nested, values: value?.isObject == true ? value! : .object([]), disabled: disabled,
                                    onValues: { onValue($0) },
                                    onInvalid: { name, message in onInvalid("\(field.name).\(name)", message) })
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
            )
        } else if field.kind == .array, let itemKind = field.itemKind {
            McpArrayControl(kind: itemKind, options: field.itemOptions, value: value, disabled: disabled, onValue: onValue)
        } else if field.kind == .array || field.kind == .json {
            McpJsonBox(value: value, placeholder: field.kind == .array ? "[]" : "{}", disabled: disabled,
                       onValue: onValue, onInvalid: { onInvalid(field.name, $0) })
        } else {
            McpPrimitiveControl(kind: field.kind, options: field.options, value: value, required: field.required,
                                disabled: disabled, onValue: onValue)
        }
    }
}

/// `String(value)` for a text box showing a value that is not text.
private func mcpPlainString(_ value: OrderedJSON) -> String {
    switch value {
    case .string(let text): return text
    case .number(let n): return OrderedJSON.jsNumber(n)
    case .bool(let b): return b ? "true" : "false"
    case .null: return "null"
    case .array(let items): return items.map { $0 == .null ? "" : mcpPlainString($0) }.joined(separator: ",")
    case .object: return "[object Object]"
    }
}

/// `PrimitiveControl`: a checkbox, a picker, a number box or a text box.
struct McpPrimitiveControl: View {
    let kind: McpFieldKind
    let options: [McpEnumOption]?
    let value: OrderedJSON?
    let required: Bool
    let disabled: Bool
    let onValue: (OrderedJSON?) -> Void
    /// What was typed into a number box, so "1." is not rewritten to "1" mid-word.
    @State private var typed: String?

    var body: some View {
        switch kind {
        case .boolean:
            Toggle("", isOn: Binding(get: { value == .bool(true) }, set: { onValue(.bool($0)) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(disabled)
        case .enum where options != nil:
            let list = options ?? []
            Picker("", selection: Binding<Int>(
                get: { McpSchema.selectIndex(list, value) ?? -1 },
                set: { onValue($0 >= 0 && $0 < list.count ? list[$0].value : nil) }
            )) {
                Text(required ? "Choose…" : "Not set").tag(-1)
                ForEach(Array(list.enumerated()), id: \.offset) { index, option in
                    Text(option.label).tag(index)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(disabled)
        case .number, .integer:
            TextField("", text: Binding(
                get: { typed ?? (value?.number.map(OrderedJSON.jsNumber) ?? "") },
                set: { text in
                    typed = text
                    onValue(McpSchema.number(text, integer: kind == .integer))
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            .frame(maxWidth: 220)
            .disabled(disabled)
        default:
            TextField("", text: Binding(
                get: { value.map(mcpPlainString) ?? "" },
                set: { onValue($0.isEmpty ? nil : .string($0)) }
            ))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .disabled(disabled)
        }
    }
}

/// `ArrayControl`: one row per item with a − beside it, and Add item.
///
/// An untouched row is `null` here where the page holds `undefined`; both are
/// dropped before sending (`McpSchema.prune`).
struct McpArrayControl: View {
    let kind: McpFieldKind
    let options: [McpEnumOption]?
    let value: OrderedJSON?
    let disabled: Bool
    let onValue: (OrderedJSON?) -> Void

    var body: some View {
        let items = value?.array ?? []
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 6) {
                    McpPrimitiveControl(kind: kind, options: options, value: item == .null ? nil : item,
                                        required: false, disabled: disabled) { next in
                        var copy = items
                        copy[index] = next ?? .null
                        onValue(.array(copy))
                    }
                    Button {
                        var copy = items
                        copy.remove(at: index)
                        onValue(.array(copy))
                    } label: {
                        Text("−").frame(width: 14)
                    }
                    .disabled(disabled)
                    .accessibilityLabel("Remove item \(index + 1)")
                }
            }
            Button("Add item") {
                onValue(.array(items + [kind == .boolean ? .bool(false) : kind == .string ? .string("") : .null]))
            }
            .controlSize(.small)
            .disabled(disabled)
        }
    }
}

/// `JsonBox`: keeps what was typed; a parse error shows under it and blocks the call.
struct McpJsonBox: View {
    let placeholder: String
    let disabled: Bool
    let onValue: (OrderedJSON?) -> Void
    let onInvalid: (String?) -> Void
    @State private var text: String
    @State private var error: String?

    init(value: OrderedJSON?, placeholder: String, disabled: Bool,
         onValue: @escaping (OrderedJSON?) -> Void, onInvalid: @escaping (String?) -> Void) {
        self.placeholder = placeholder
        self.disabled = disabled
        self.onValue = onValue
        self.onInvalid = onInvalid
        _text = State(initialValue: value.map(\.pretty) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            McpTextBox(text: $text, placeholder: placeholder, minHeight: 72, invalid: error != nil, disabled: disabled)
                .onChange(of: text) { _, next in change(next) }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func change(_ next: String) {
        let read = McpSchema.readJSONBox(next)
        error = read.error
        onInvalid(read.error)
        if read.error == nil { onValue(read.value) }
    }
}

// MARK: - Adding or editing a server (McpAddForm)

/// `McpAddForm`: the same fields to add a server or change one; the store's
/// Edit and Import open it with a start.
struct McpAddFormView: View {
    enum Mode { case add, edit }

    let projectPath: String?
    let mode: Mode
    let start: McpFormStart?
    let onSubmit: @MainActor ([String: Any]) async throws -> McpAddResult
    let onAdded: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    @State private var draft: McpAddDraft
    @State private var busy = false
    @State private var error: String?

    init(projectPath: String?, mode: Mode = .add, start: McpFormStart? = nil,
         onSubmit: @escaping @MainActor ([String: Any]) async throws -> McpAddResult,
         onAdded: @escaping @MainActor (String) -> Void,
         onCancel: @escaping @MainActor () -> Void) {
        self.projectPath = projectPath
        self.mode = mode
        self.start = start
        self.onSubmit = onSubmit
        self.onAdded = onAdded
        self.onCancel = onCancel
        _draft = State(initialValue: start?.draft ?? McpAddDraft())
    }

    private var editing: Bool { mode == .edit }
    private var stdio: Bool { draft.transport == .stdio }

    var body: some View {
        let choices = McpScopeChoice.choices(projectPath: projectPath)
        let missing = draft.missing
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    caption("Name")
                    TextField("", text: $draft.name, prompt: Text("filesystem"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(submit)
                }
                GridRow {
                    caption("How it is reached")
                    Picker("", selection: $draft.transport) {
                        ForEach(McpAddTransport.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    caption(stdio ? "Command" : "URL")
                    TextField("", text: stdio ? $draft.command : $draft.url,
                              prompt: Text(stdio ? "npx -y @modelcontextprotocol/server-filesystem ~/Documents" : "https://example.com/mcp"))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .onSubmit(submit)
                }
                GridRow(alignment: .top) {
                    HStack(spacing: 4) {
                        caption(stdio ? "Environment variables" : "Headers")
                        if editing, stdio, let note = start?.savedNote {
                            NativeCodingAIInfo(label: "Leave a value blank to keep it", text: note)
                        }
                    }
                    .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        McpTextBox(text: $draft.extras, placeholder: stdio ? "API_KEY=…" : "Authorization: Bearer …", minHeight: 44)
                        if editing && !stdio {
                            Text("This app does not read an HTTP server’s headers back, so it cannot show you the ones that are there. Saving replaces them with whatever is in this box.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                GridRow {
                    HStack(spacing: 4) {
                        caption("Save it for")
                        NativeCodingAIInfo(label: "Where this gets saved",
                                           text: McpScopeChoice.note(scope: draft.scope, projectPath: projectPath))
                    }
                    Picker("", selection: $draft.scope) {
                        ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .disabled(busy)

            if let error { NativeCodingAINotice(tone: .error, text: error) }

            HStack(spacing: 8) {
                Button(busy ? (editing ? "Saving…" : "Adding…") : editing ? "Save changes" : "Add server", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || missing != nil)
                    .help(missing ?? "")
                Button("Cancel") { onCancel() }
                    .disabled(busy)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.45)))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private func submit() {
        if let missing = draft.missing {
            error = missing
            return
        }
        busy = true
        error = nil
        let request = draft.request(projectPath: projectPath)
        Task { @MainActor in
            do {
                let result = try await onSubmit(request)
                busy = false
                if result.ok {
                    if !editing { draft = McpAddDraft() }
                    onAdded(result.message)
                    return
                }
                error = result.message
            } catch {
                busy = false
                self.error = mcpMessage(error)
            }
        }
    }
}
