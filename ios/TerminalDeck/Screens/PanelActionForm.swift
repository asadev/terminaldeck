/**
 * The sheet behind any panel action that asks for something first.
 *
 * > *"All the features and options to edit or add or whatever the actions we
 * > have in the desktop app should be in mobile app too."*
 *
 * `PanelAction.fields` is what makes that reachable without a wire frame per
 * verb: the host declares the boxes, this draws them, and what comes back is a
 * `[String: String]` on `panel.act` that only the host understands. Nothing in
 * this file knows what an MCP command is, what a scope means, or which of the
 * two ways of naming a server the person is going to use.
 *
 * ## One form serves add and edit
 *
 * `PanelField.value` prefilled is the whole mechanism — *"Editing is the same
 * form prefilled from the row"*, as `mcp.ts` puts it, where both actions call
 * the same `formFields` builder and differ only in what they hand it. So this
 * screen has no notion of *new* or *existing* either: it opens on whatever it
 * was given.
 *
 * ## Nothing here is a sentence, so nothing here is autocorrected
 *
 * Every box on these forms is a command, a path, a URL, a server name or an
 * environment line. Not one of them is prose, and iOS assumes prose: an address
 * typed with capitalisation on arrives as `Localhost` and one typed with
 * autocorrect on arrives as `local host`. This app has been bitten by exactly
 * that before — the address bar, the history search and the saved-logins search
 * all carry the same two lines with the same note — so both are off on every
 * field here rather than on the ones somebody guessed would need it.
 *
 * ## Where the long placeholders go
 *
 * The host writes some of them as an example, an em dash, and then a sentence:
 * *"https://example.com/mcp — fill this in instead of the command"*,
 * *"Authorization: Bearer … — headers are not read back, so saving replaces
 * them"*. All of that in a one-line box is a truncated example with the
 * explanation cut off the end of it, and *"I don't want any kind of long
 * descriptions anywhere — just if somewhere it's very required, give the i
 * icon"* says where the second half belongs. So the example stays in the box and
 * the sentence goes behind the `InfoDot` on the label, split on the host's own
 * dash rather than on a length this file guessed at.
 *
 * ## A destructive action is confirmed here, not before here
 *
 * `PanelView` raises the confirmation itself for an action with no fields. One
 * that has fields is confirmed from inside this sheet instead: asking *are you
 * sure* about a form nobody has filled in yet is a question with no answer, and
 * the person still has a Cancel that costs nothing either way.
 */

import SwiftUI
import UIKit

/**
 * One action and the row it was raised from, as a sheet's item.
 *
 * `rowKey` is `PanelRow.key` — *what the row is on the machine* — and not the
 * row's position, which is what `PanelRow.id` carries and which stops being true
 * the moment the list is filtered between the tap and the frame going out.
 * `subject` is the row's title, and it is display text: it names the sheet so
 * that a form over a machine somebody cannot see says which server it is about.
 */
struct PanelActionTarget: Identifiable, Equatable {
    let action: PanelAction
    /// Absent for a panel-level action, which names no row.
    let rowKey: String?
    /// What the row is called, or nil for a panel-level action.
    let subject: String?

    /// The action **and** the row, because one action id serves every row on the
    /// panel: identifying a sheet by the action alone would leave `.sheet(item:)`
    /// believing that editing one server and editing the next are the same
    /// presentation, and it would not rebuild the form between them.
    var id: String { "\(action.id)\u{0}\(rowKey ?? "")" }
}

struct PanelActionForm: View {
    /// The row this is about, or the panel's own title. Drawn as the sheet's
    /// heading, which is what makes the confirm button able to be a bare verb.
    let title: String
    let action: PanelAction
    /// What was typed, by field id. The sheet dismisses itself; the caller sends.
    let submit: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss

    /// What is in the boxes. Seeded from the fields' own values, which is what
    /// makes one action serve both add and edit.
    @State private var values: [String: String]
    @State private var confirming = false

    init(title: String, action: PanelAction, submit: @escaping ([String: String]) -> Void) {
        self.title = title
        self.action = action
        self.submit = submit
        // Built by assignment rather than `Dictionary(uniqueKeysWithValues:)`,
        // which traps on a repeated key. A host that sent the same field id
        // twice is a host with a bug; it is not a reason to kill the app on a
        // phone somebody is holding.
        var seeded: [String: String] = [:]
        for field in action.fields { seeded[field.id] = field.value }
        _values = State(initialValue: seeded)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    card {
                        ForEach(Array(action.fields.enumerated()), id: \.offset) { index, field in
                            if index > 0 { line }
                            row(field)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("panel.form.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    /*
                     * The action's own words, not "Save" or "Done".
                     *
                     * The host already wrote the verb — *Add a server*, *Edit*,
                     * *Remove* — and it is the only party that knows what
                     * pressing this does. A generic word here would be this
                     * screen inventing a name for something it does not
                     * understand, which is exactly what the rest of this design
                     * refuses to do.
                     */
                    Button(action.label) { confirm() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(action.destructive ? Theme.warning : Theme.accent)
                        .disabled(!ready)
                        .accessibilityIdentifier("panel.form.submit")
                }
            }
            .confirmationDialog("\(action.label)?",
                                isPresented: $confirming,
                                titleVisibility: .visible) {
                Button(action.label, role: .destructive) { send() }
                Button("Keep", role: .cancel) {}
            } message: {
                if let line = action.confirm, !line.isEmpty { Text(line) }
            }
        }
    }

    // MARK: - Whether it can go

    /**
     * Every required field has something in it.
     *
     * Measured on the trimmed text, because a box holding a space is a box
     * somebody has not filled in — and the host trims too, so a form that let a
     * space through would send a request the machine refuses for a reason
     * nothing on this phone explained.
     */
    private var ready: Bool {
        action.fields.allSatisfy { field in
            !field.required || !text(field.id).trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func confirm() {
        if action.destructive {
            confirming = true
        } else {
            send()
        }
    }

    /**
     * Off it goes, **as typed**.
     *
     * Not trimmed here even though `ready` measures trimmed text, and the two
     * are not in conflict: the host trims what it needs to and this end cannot
     * know which fields those are. A command whose trailing space this screen
     * ate would be a command changed on the way to the machine by a phone that
     * had no opinion about it.
     */
    private func send() {
        submit(values)
        dismiss()
    }

    // MARK: - One field

    private func row(_ field: PanelField) -> some View {
        let split = Self.split(field.placeholder)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(field.label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = split.note {
                    InfoDot(about: field.label, text: note)
                }
                Spacer(minLength: 0)
            }
            TextField(split.placeholder ?? "", text: binding(field.id))
                .font(.system(size: 16))
                .foregroundStyle(Theme.primary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(Self.keyboard(field))
                .textContentType(Self.isAddress(field) ? .URL : nil)
                .submitLabel(.done)
                .accessibilityLabel(field.label)
                .accessibilityIdentifier("panel.form.field.\(field.id)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func text(_ id: String) -> String { values[id] ?? "" }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { text(id) }, set: { values[id] = $0 })
    }

    // MARK: - Reading a field without understanding it

    /**
     * The placeholder, and the sentence that was stuck to the end of it.
     *
     * Split on the host's own *space em-dash space*, which is how `mcp.ts`
     * writes the two-part ones. A placeholder with no dash is left whole; if it
     * is long enough that the box will cut it, it is *also* put behind the dot,
     * so nothing the host wrote is only ever readable in a truncated form.
     *
     * 48 is roughly what a 16-point field spans across the narrowest phone this
     * app runs on. It is a threshold for offering a second way to read a
     * sentence, not a layout constraint, so being a few characters out either
     * way costs nothing.
     */
    static func split(_ placeholder: String?) -> (placeholder: String?, note: String?) {
        guard let placeholder, !placeholder.isEmpty else { return (nil, nil) }
        if let dash = placeholder.range(of: " — ") {
            return (String(placeholder[..<dash.lowerBound]),
                    String(placeholder[dash.upperBound...]))
        }
        return (placeholder, placeholder.count > 48 ? placeholder : nil)
    }

    /**
     * A URL keyboard for the one field that takes one, and an ASCII keyboard for
     * everything else.
     *
     * Keyed on the field **id**, which is the host's own machine-readable name
     * for it, rather than on the label, which is a sentence somebody wrote and
     * changes when the wording changes. `.asciiCapable` for the rest because a
     * command line has no use for an emoji key, and the app already spends this
     * exact keyboard on the hex boxes in the scheme editor and on an SSH
     * username.
     */
    static func keyboard(_ field: PanelField) -> UIKeyboardType {
        isAddress(field) ? .URL : .asciiCapable
    }

    /// Whether this field takes a URL. `url`, or something ending `.url` —
    /// deliberately not any id merely *containing* the three letters, which
    /// would catch `curl` on a panel whose command field was named for the tool
    /// it runs.
    static func isAddress(_ field: PanelField) -> Bool {
        let id = field.id.lowercased()
        return id == "url" || id.hasSuffix(".url") || id.hasSuffix("_url")
    }

    // MARK: - Its own chrome

    /// The card every other screen in this app draws — `Theme.surface` at radius
    /// 20 — written here rather than borrowed, for the reason `PanelView` and
    /// `MachineDetailView` both record: the settings versions are private to
    /// `DeckTabs.swift`.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}
