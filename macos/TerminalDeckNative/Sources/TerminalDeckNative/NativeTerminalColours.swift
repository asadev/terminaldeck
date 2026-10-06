import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Appearance → Terminal colours (`TerminalColours.tsx`): the row with
/// "Paste a scheme", the cards (Follow the app, every scheme that came with the
/// app, then the person's own), and for the chosen one Edit colours, Copy as
/// JSON, Duplicate — and Rename and Delete for one of their own. Editing a
/// colour repaints every open session as it moves; a scheme that came with the
/// app is copied rather than changed.
struct NativeTerminalColours: View {
    private let store = NativeSettingsValues.shared
    @State private var editing = false
    @State private var importing = false
    @State private var pasted = ""
    @State private var note: String?
    @State private var problem: String?
    @State private var renaming: String?

    var body: some View {
        let values = store.values.mapValues(\.foundation)
        let customs = TerminalSchemes.customs(in: values)
        let chosen = TerminalColours.chosenId(values)
        let active = chosen == TerminalSchemes.followApp ? nil : TerminalSchemes.pinned(in: values)
        let full = customs.count >= TerminalColours.maxCustom
        let disabled = store.loading
        VStack(alignment: .leading, spacing: 10) {
            NativeSettingRow(label: "Terminal colours", help: TerminalColours.rowHelp(active: active), more: TerminalColours.more) {
                Button(importing ? "Cancel" : "Paste a scheme") { importing.toggle() }
                    .disabled(disabled)
            }
            if importing {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $pasted)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 90)
                        .overlay(alignment: .topLeading) {
                            if pasted.isEmpty {
                                Text(TerminalColours.pastePlaceholder)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                        .accessibilityLabel("Scheme JSON")
                    Text(TerminalColours.pasteHelp).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Add scheme") { paste(customs: customs, full: full) }
                            .buttonStyle(.borderedProminent)
                            .disabled(disabled || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") {
                            importing = false
                            problem = nil
                        }
                    }
                }
            }
            if let problem {
                NativeCodingAINotice(tone: .warn, text: problem)
            } else if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                FollowCard(selected: active == nil) { pick(TerminalSchemes.followApp) }
                ForEach(TerminalSchemes.builtins + customs, id: \.id) { scheme in
                    SchemeCard(scheme: scheme, selected: active?.id == scheme.id) { pick(scheme.id) }
                }
            }
            if let active {
                HStack(spacing: 8) {
                    Button(editing ? "Done editing" : "Edit colours") {
                        if editing { NativeTerminalSettings.shared.preview(nil) }
                        editing.toggle()
                    }
                    .disabled(disabled)
                    Button("Copy as JSON") { copyJSON(active) }.disabled(disabled)
                    Button("Duplicate") { duplicate(active, customs: customs) }
                        .disabled(disabled || full)
                        .help(full ? TerminalColours.fullShort : "")
                    if !TerminalColours.isBuiltin(active.id) {
                        Button("Rename") { renaming = active.name }.disabled(disabled)
                        Button("Delete", role: .destructive) { remove(active) }.disabled(disabled)
                    }
                }
                if let draft = renaming {
                    HStack(spacing: 8) {
                        TextField("", text: Binding(get: { draft }, set: { renaming = String($0.prefix(TerminalColours.maxName)) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .accessibilityLabel("Scheme name")
                        Button("Save name") {
                            rename(active, to: draft)
                            renaming = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(TerminalColours.cleanName(draft).isEmpty)
                        Button("Cancel") { renaming = nil }
                    }
                }
                if editing {
                    ColourEditor(scheme: NativeTerminalSettings.shared.previewing ?? active,
                                 live: { slot, colour in NativeTerminalSettings.shared.preview(active.with(slot, colour)) },
                                 commit: { slot, colour in change(active, slot: slot, colour: colour, customs: customs, full: full) })
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Writing (each write also repaints every open session)

    private func write(_ patch: [String: CodingAIJSON]) {
        store.save(patch)
        NativeTerminalSettings.shared.preview(nil)
        NativeTerminalSettings.shared.reload()
    }

    private func pick(_ id: String) {
        problem = nil
        note = nil
        write([TerminalSchemes.settingKey: .string(id)])
    }

    private func change(_ active: TerminalScheme, slot: String, colour: String, customs: [TerminalScheme], full: Bool) {
        let edited = active.with(slot, colour)
        if !TerminalColours.isBuiltin(active.id) {
            write([TerminalSchemes.customPrefix + active.id: .string(TerminalColours.stored(edited))])
            return
        }
        if full {
            problem = TerminalColours.full
            return
        }
        let copy = TerminalColours.copy(edited, taken: customs.map(\.id))
        write([TerminalSchemes.customPrefix + copy.id: .string(TerminalColours.stored(copy)),
               TerminalSchemes.settingKey: .string(copy.id)])
        note = "Editing a scheme that came with the app made you a copy — \(copy.name)."
    }

    private func duplicate(_ active: TerminalScheme, customs: [TerminalScheme]) {
        guard customs.count < TerminalColours.maxCustom else { return }
        let copy = TerminalColours.copy(active, taken: customs.map(\.id))
        write([TerminalSchemes.customPrefix + copy.id: .string(TerminalColours.stored(copy)),
               TerminalSchemes.settingKey: .string(copy.id)])
        note = "Copied to \(copy.name)."
    }

    private func remove(_ active: TerminalScheme) {
        guard !TerminalColours.isBuiltin(active.id) else { return }
        write([TerminalSchemes.settingKey: .string(TerminalSchemes.followApp),
               TerminalSchemes.customPrefix + active.id: .null])
        editing = false
        note = "Deleted \(active.name)."
    }

    private func rename(_ active: TerminalScheme, to name: String) {
        guard !TerminalColours.isBuiltin(active.id) else { return }
        let cleaned = TerminalColours.cleanName(name)
        guard !cleaned.isEmpty else { return }
        write([TerminalSchemes.customPrefix + active.id: .string(TerminalColours.stored(active.renamed(name: cleaned)))])
    }

    private func paste(customs: [TerminalScheme], full: Bool) {
        if full {
            problem = TerminalColours.full
            return
        }
        switch TerminalColours.parse(pasted, taken: customs.map(\.id)) {
        case .problem(let why):
            problem = why
        case .ok(let scheme):
            write([TerminalSchemes.customPrefix + scheme.id: .string(TerminalColours.stored(scheme)),
                   TerminalSchemes.settingKey: .string(scheme.id)])
            pasted = ""
            importing = false
            problem = nil
            note = "Added \(scheme.name)."
        }
    }

    private func copyJSON(_ active: TerminalScheme) {
        let board = NSPasteboard.general
        board.clearContents()
        if board.setString(TerminalColours.export(active), forType: .string) {
            note = "\(active.name) copied as JSON."
        } else {
            problem = "This window could not reach the clipboard."
        }
    }
}

// MARK: - Cards

private struct FollowCard: View {
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Follow the app").font(.callout.weight(.semibold))
                Text(TerminalColours.followNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(10)
            .modifier(CardFrame(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SchemeCard: View {
    let scheme: TerminalScheme
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(scheme.name).font(.callout.weight(.semibold)).lineLimit(1)
                    if !TerminalColours.isBuiltin(scheme.id) {
                        Text("yours")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                }
                SchemePreview(scheme: scheme)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .modifier(CardFrame(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(scheme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CardFrame: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content
            .background(.background.secondary, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                   lineWidth: selected ? 2 : 1))
            .contentShape(.rect(cornerRadius: 10))
    }
}

/// `SchemePreview`: a prompt line, a test result line, selected output and the sixteen swatches.
private struct SchemePreview: View {
    let scheme: TerminalScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                line(TerminalColours.previewLine)
                Text("_").foregroundStyle(colour(scheme.cursorAccent)).background(colour(scheme.cursor))
            }
            line(TerminalColours.previewLineTwo)
            Text("selected output")
                .foregroundStyle(colour(scheme.foreground))
                .background(colour(scheme.selectionBackground))
            HStack(spacing: 2) {
                ForEach(Array(scheme.ansi.enumerated()), id: \.offset) { _, hex in
                    RoundedRectangle(cornerRadius: 2).fill(colour(hex)).frame(height: 8)
                }
            }
            .padding(.top, 2)
        }
        .font(.system(size: 10, design: .monospaced))
        .lineLimit(1)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colour(scheme.background), in: .rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    private func line(_ runs: [(text: String, slot: String)]) -> Text {
        runs.reduce(Text("")) { sum, run in
            sum + Text(run.text).foregroundColor(colour(scheme.colour(run.slot)))
        }
    }

    private func colour(_ hex: String) -> Color {
        Color(nsColor: TerminalColour(hex: hex)?.nsColor ?? .gray)
    }
}

// MARK: - The editor

/// The chosen scheme's colours, one row each: the swatch, a picker and the hex.
private struct ColourEditor: View {
    let scheme: TerminalScheme
    let live: (String, String) -> Void
    let commit: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SchemePreview(scheme: scheme).frame(maxWidth: 300)
            Text(TerminalColours.contrastLine(scheme)).font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(TerminalColours.slots, id: \.self) { slot in
                    ColourRow(slot: slot, value: scheme.colour(slot), live: live, commit: commit)
                }
            }
            Text(TerminalColours.lightness(scheme)).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// `ColourRow`: a colour well that repaints while it moves and saves when it rests,
/// and a hex field that keeps what was typed until it is legal (and goes back on blur
/// when it never is). Transparency in the stored colour is kept.
private struct ColourRow: View {
    let slot: String
    let value: String
    let live: (String, String) -> Void
    let commit: (String, String) -> Void
    @State private var text = ""
    @State private var resting: Task<Void, Never>?
    @FocusState private var editingHex: Bool

    var body: some View {
        let label = TerminalColours.labels[slot] ?? slot
        HStack(spacing: 8) {
            Text(label).frame(width: 140, alignment: .leading)
            ColorPicker(label, selection: Binding(get: { Self.color(value) }, set: { picked in
                let next = Self.hex(picked) + TerminalColours.alpha(value)
                live(slot, next)
                resting?.cancel()
                resting = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    if !Task.isCancelled { commit(slot, next) }
                }
            }), supportsOpacity: false)
            .labelsHidden()
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 96)
                .focused($editingHex)
                .foregroundStyle(TerminalColour.normalise(text) == nil ? Color.red : Color.primary)
                .accessibilityLabel("\(label) hex")
                .onChange(of: text) { _, typed in
                    if editingHex, let colour = TerminalColour.normalise(typed) { live(slot, colour) }
                }
                .onSubmit { settle() }
                .onChange(of: editingHex) { _, now in if !now { settle() } }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, now in if !editingHex { text = now } }
    }

    private func settle() {
        if let colour = TerminalColour.normalise(text) { commit(slot, colour) } else { text = value }
    }

    static func color(_ hex: String) -> Color {
        Color(nsColor: TerminalColour(hex: TerminalColours.opaque(hex))?.nsColor ?? .black)
    }

    static func hex(_ color: Color) -> String {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func two(_ c: CGFloat) -> String { String(format: "%02x", Int((max(0, min(1, c)) * 255).rounded())) }
        return "#" + two(rgb.redComponent) + two(rgb.greenComponent) + two(rgb.blueComponent)
    }
}
