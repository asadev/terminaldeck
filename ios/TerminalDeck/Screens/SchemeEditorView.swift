/**
 * Editing one scheme's twenty-one colours.
 *
 * ## It is always a copy, and the copy is already the one in use
 *
 * There is no way to reach this screen on a built-in: `AppearanceView.edit`
 * duplicates first and selects the duplicate, so from the first tap the person
 * is changing their own scheme and the terminal behind this screen is following
 * them. The alternative — let them edit Dracula for a minute and then either
 * ship a Dracula that is not Dracula, or spring a "this made a copy" at the end
 * — is worse in both directions.
 *
 * ## Live, on every touch, with no Save
 *
 * Every well and every field writes straight through `TerminalThemeStore`, which
 * posts `terminalSchemeChanged`, which repaints any session already on screen.
 * That is the requirement — *applies live* — and it also removes the state this
 * screen would otherwise have to hold: there is no draft, no dirty flag and
 * nothing to lose by leaving. Backing out is Undo's job and this app does not
 * pretend otherwise; the scheme is a copy, so the original is still on the list
 * above, untouched.
 *
 * ## Two ways into every colour, because they answer different questions
 *
 * The **well** opens `UIColorPickerViewController` — the system picker, with its
 * spectrum, its sliders and its eyedropper. That is for *finding* a colour.
 * The **hex field** beside it is for *matching* one: somebody porting the scheme
 * they already use on the desktop has the hexes, and a spectrum wheel is a bad
 * way to enter `#8be9fd`. The field takes `#8be9fd`, the shorthand `#8bf`, and
 * `#3b8fee29` with an alpha — the same three forms `normaliseColour` accepts on
 * the desktop, no looser, so a value that works in one product works in the
 * other. It settles on the canonical spelling when it loses focus.
 *
 * A half-typed value never reaches the terminal: `TerminalPalette.isColor` gates
 * the write, so `#8b` is a string in a text field rather than a black terminal
 * somebody now has to type the rest of the colour into.
 */

import SwiftUI

struct SchemeEditorView: View {

    var themes: TerminalThemeStore = .shared
    let schemeID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var name: String = ""
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    /// The scheme as the store holds it right now. Read through rather than
    /// copied into `@State`, so the preview at the top and the wells below it
    /// cannot disagree, and so a delete from anywhere leaves this screen with
    /// nothing stale to draw.
    private var scheme: TerminalScheme {
        themes.scheme(id: schemeID) ?? TerminalScheme.builtIns[0]
    }

    /// False only if this screen is somehow standing on a shipped palette. It
    /// cannot be reached that way — `AppearanceView.edit` copies first — but
    /// a screen that would silently write into a built-in if it ever were is a
    /// screen that eventually does.
    private var isEditable: Bool { !scheme.isBuiltIn }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    preview
                    nameRow
                    terminalColors
                    normalColors
                    brightColors
                    if isEditable { deleteRow }
                    // Measured, not guessed — see `TabBarClearance`.
                    TabBarClearance()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                // The floating pill is drawn over this screen — it is pushed inside
                // the Settings stack, where `settingsSurface` resolves to
                // `.machines`, which keeps the bar. A bare 28 was the copied
                // constant `TabBarClearance` exists to replace: the bar's real
                // band is 83 points, so the last scheme card sat behind it.
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(scheme.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = scheme.name }
        .confirmationDialog("Delete this scheme?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                themes.delete(schemeID)
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("\(scheme.name) is only on this phone. Deleting it cannot be undone.")
        }
    }

    // MARK: - Pieces

    /// Pinned at the top rather than under the fields, because every change made
    /// below is judged here and a preview that has to be scrolled back to is a
    /// preview nobody looks at. Drawn at the terminal's real point size.
    private var preview: some View {
        SchemePreview(scheme: scheme, size: TextSize.stored, colorScheme: colorScheme)
            .accessibilityIdentifier("editor.preview")
    }

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchemeSectionCaption("Name")
            SchemeGroup {
                HStack(spacing: 12) {
                    // The row-icon metrics the whole app is on now — 19 light
                    // in a 24-point column. See `SettingsRowBody`.
                    Image(systemName: "textformat")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24)
                    TextField("Name", text: $name)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                        .focused($nameFocused)
                        .disabled(!isEditable)
                        .submitLabel(.done)
                        // Committed as it is typed rather than on Done, so the
                        // list behind this screen and the title above it are
                        // never showing a name the store does not have. The
                        // store trims and bounds it; the field keeps whatever
                        // was typed until focus leaves, so a trailing space
                        // being eaten mid-word does not fight the keyboard.
                        .onChange(of: name) { _, new in themes.rename(schemeID, to: new) }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { name = scheme.name }
                        }
                        .accessibilityIdentifier("editor.name")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            if !isEditable {
                Text("This scheme ships with \(Brand.name) and cannot be changed. "
                     + "Copy it from the list to make one of your own.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
        }
    }

    private var terminalColors: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchemeSectionCaption("Terminal")
            SchemeGroup {
                ForEach(Array(ColourSlot.surface.enumerated()), id: \.element) { index, slot in
                    if index > 0 { SchemeDivider() }
                    ColorSlotRow(label: slot.label,
                                 hex: binding(slot),
                                 editable: isEditable,
                                 // On the row rather than in a paragraph under
                                 // the card. It is about one of the five, and a
                                 // note at the foot of a group is read after
                                 // the well has already eaten the two digits it
                                 // was warning about.
                                 info: slot == .selectionBackground ? Self.selectionNote : nil)
                }
            }
        }
    }

    /// Behind the ⓘ on the Selection row. The selection is the one slot that
    /// carries an alpha and the well cannot express one — see `ColorSlotRow` —
    /// so this is the difference between a highlight and a solid band painted
    /// over the text it covers.
    private static let selectionNote =
        "The selection is drawn under text, so it is usually part transparent. Type eight "
        + "digits — \(TerminalScheme.builtIns[0].selectionBackground) — to set that; the colour "
        + "well sets the first six."

    private var normalColors: some View {
        VStack(alignment: .leading, spacing: 0) {
            /*
             * The one thing worth knowing **before** spending time in here, and
             * that is why it is on this caption rather than under the last of
             * the sixteen where it used to be — it was an answer printed after
             * the question had been paid for. Same caveat `Ink.ansi` records: an
             * agent that emits 24-bit colour bypasses all sixteen of these.
             */
            SchemeSectionCaption("ANSI colours",
                                 about: "the sixteen",
                                 info: "Programs that print full-colour output name their own "
                                     + "colours and ignore these sixteen. Everything else — "
                                     + "shells, agents, diffs, test runners — uses them.")
            SchemeGroup {
                ForEach(Array(ColourSlot.ansi.prefix(8).enumerated()), id: \.element) { index, slot in
                    if index > 0 { SchemeDivider() }
                    ColorSlotRow(label: slot.label, hex: binding(slot), editable: isEditable)
                }
            }
        }
    }

    private var brightColors: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchemeSectionCaption("Bright")
            SchemeGroup {
                ForEach(Array(ColourSlot.ansi.suffix(8).enumerated()), id: \.element) { index, slot in
                    if index > 0 { SchemeDivider() }
                    ColorSlotRow(label: slot.label, hex: binding(slot), editable: isEditable)
                }
            }
        }
    }

    private var deleteRow: some View {
        Button(role: .destructive) { confirmingDelete = true } label: {
            Label("Delete scheme", systemImage: "trash")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.critical)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.top, 24)
        .accessibilityIdentifier("editor.delete")
    }

    // MARK: - Bindings

    /**
     * One slot of the stored scheme, read live and written straight through.
     *
     * The write goes through `TerminalScheme.with`, which refuses anything that
     * is not a colour and hands the scheme back unchanged — the same rule
     * `withColour` keeps on the desktop, and the reason a hex field can hold
     * `#8b` for a moment without the terminal going black.
     */
    private func binding(_ slot: ColourSlot) -> Binding<String> {
        Binding(get: { scheme[slot] },
                set: { themes.update(scheme.with(slot, $0)) })
    }
}

/* -------------------------------------------------------------------------- */
/* One colour                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * A label, a hex field and a well.
 *
 * The well is a `ColorPicker` with its own label hidden rather than a button
 * raising a sheet, because `ColorPicker` *is* `UIColorPickerViewController` —
 * the system picker with the eyedropper in it, which is the one control here
 * nobody has to be taught.
 *
 * Opacity is off, and the alpha is kept anyway. Twenty of the twenty-one slots
 * are opaque by nature — the emulator takes a solid colour for every one of
 * them — but the selection is drawn *under* text and several shipped schemes
 * carry `#rrggbbaa` there. So the well edits the first six digits and puts the
 * existing alpha back on the end; the hex field beside it is where an alpha is
 * typed. An opacity slider on all twenty-one would offer a setting that twenty
 * of them silently throw away.
 */
private struct ColorSlotRow: View {
    let label: String
    @Binding var hex: String
    let editable: Bool
    /// What the ⓘ beside this label says, on the one slot in twenty-one that
    /// has something about it the label cannot carry. Nil on the other twenty.
    var info: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(Theme.primary)
            if let info {
                InfoDot(about: label.lowercased(), text: info)
            }
            Spacer(minLength: 8)
            HexField(hex: $hex, editable: editable)
            ColorPicker("", selection: swatch, supportsOpacity: false)
                .labelsHidden()
                .disabled(!editable)
                .accessibilityIdentifier("slot.\(label)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var swatch: Binding<Color> {
        Binding(get: { TerminalPalette.swiftUIColor(TerminalPalette.opaquePart(hex), fallback: .black) },
                // The alpha the slot already had, put back on the end. Without
                // this line, opening the picker on a selection colour and
                // closing it again would quietly turn `#3b8fee29` into a solid
                // band across the text it covers.
                set: { hex = TerminalPalette.hex($0) + TerminalPalette.alphaPart(hex) })
    }
}

/**
 * The hex field.
 *
 * Its own `@State` copy of the text rather than binding the store directly, and
 * the reason is what a person types: `#`, then `8`, then `b`. Bound straight
 * through, every one of those keystrokes is either a write of an invalid value
 * or — worse — a value the store rejects and hands back, which yanks the cursor
 * to the end of a field somebody is still typing in.
 *
 * So the field holds the typing, and a write happens only when what is in it is
 * a **finished** colour — six digits or eight. That second word was earned by
 * watching it: `#8be9fd` typed one character at a time passes through `#8be`,
 * which is a perfectly legal three-digit colour, and through `#8be9`, which is a
 * legal four-digit one *with an alpha*. Committing every valid intermediate
 * meant the terminal behind the editor flashed through two colours nobody asked
 * for on the way to the one they did, and briefly went translucent.
 *
 * The shorthand is still accepted — it is just accepted on **Done** rather than
 * mid-word, which is also when somebody typing `#8bf` has finished saying it.
 * Focus leaving snaps the field to the committed value in its canonical
 * spelling, so `#8bf` comes back as `#88bbff`.
 */
private struct HexField: View {
    @Binding var hex: String
    let editable: Bool

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("#000000", text: $text)
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(TerminalPalette.isColor(text) ? Theme.faint : Theme.critical)
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.done)
            .frame(width: 100)
            .disabled(!editable)
            .focused($focused)
            .onAppear { text = hex }
            .onChange(of: hex) { _, value in if !focused { text = value } }
            .onChange(of: text) { _, value in
                // Six or eight digits only — a finished colour. See the header.
                let typed = value.trimmingCharacters(in: .whitespaces)
                let digits = typed.hasPrefix("#") ? typed.dropFirst() : Substring(typed)
                guard digits.count == 6 || digits.count == 8 else { return }
                commit(value)
            }
            .onSubmit { commit(text) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    // Shorthand is accepted here rather than mid-word, and
                    // anything that never became a colour is discarded — the
                    // field goes back to what the scheme actually holds rather
                    // than sitting there showing a value nothing is painted in.
                    commit(text)
                    text = hex
                }
            }
    }

    private func commit(_ value: String) {
        guard let normalized = TerminalPalette.normalized(value), normalized != hex else { return }
        hex = normalized
    }
}

/// The hairline between two rows in a card, inset to the label's own left edge
/// the way `SettingsDivider` is. 16 rather than that one's 52 because these rows
/// carry no icon: the label starts at the card's own padding.
struct SchemeDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}
