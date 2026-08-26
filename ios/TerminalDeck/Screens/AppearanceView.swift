/**
 * **Appearance** — the one page that says how this app and every terminal in it
 * look. Light or dark, how big the text is, and what colours a session is drawn
 * in.
 *
 * ## Why it is a page, and why it is called this
 *
 * He was on a session, with the `…` menu open, reading two rows out of it:
 *
 * > *"this bigger and smaller should be going to inside the settings page for
 * > the all of the terminals with one setting we can just change this for
 * > overall appearance page should be there in the settings and from there we
 * > can change colors text size and everything for all of them."*
 *
 * Four things in one sentence and all four are here. The size comes **out** of
 * the session menu — see the note where it used to be in `TerminalScreen`. It
 * is **one setting for all of the terminals**, and now genuinely so: changing it
 * reaches sessions that are already open, through
 * `Notification.Name.terminalTextSizeChanged`. There is an **overall appearance
 * page in the settings**, which is this file. And **colours, text size and
 * everything** are on it, together, rather than a picker here and a stepper
 * three screens away.
 *
 * The light/dark control came with them. It was a segmented picker sitting
 * inline on the Settings screen under a caption that already said *Appearance*,
 * which would have left this app with an Appearance section and an Appearance
 * row next to each other, arguing about which one was the appearance. It is one
 * page, it is the whole answer, and Settings has one row.
 *
 * ## The three groups, in that order
 *
 * **The app** first, because it is the coarsest: it decides the paper every
 * other screen is drawn on, and — through *Follow the app* below — the terminal's
 * own colours by default. **Every terminal** second, because the size is the one
 * he came here to change. **Colours** last, because it is the longest and
 * because scrolling past a list of cards to reach a stepper is how the size got
 * lost in the first place.
 *
 * ## Colours: Asad asked for them everywhere, and named one
 *
 * *"phone also, for Windows, for MacBook, all of them"* — and the one he wanted
 * was pure black. On a phone that is not a preference like the others. An OLED
 * panel switches a `#000000` pixel off rather than lighting it, so the black
 * scheme is the only one that is actually black in a dark room, and the phone is
 * where somebody sits looking at a terminal in the dark.
 *
 * ### The first row is not a scheme
 *
 * **Follow the app** is what every install has been on since this app existed:
 * the terminal takes its ground and its ink from the phone's light/dark, so a
 * phone that crosses into dark at sunset takes its terminal with it — and so the
 * control at the top of this very page moves it. It is the default and it stays
 * the default; picking anything below it cuts that link on purpose, because
 * somebody who picks Solarized Light has picked Solarized Light. See
 * `TerminalScheme.followAppID`.
 *
 * ### Every row is the scheme, not a swatch of it
 *
 * A picker made of coloured dots tells you a scheme has a green in it. It does
 * not tell you whether an agent's failing test is readable, which is the only
 * question that matters and the reason Solarized Light and Campbell are not
 * interchangeable. So each row renders the same six lines of terminal output —
 * a prompt, a branch, a pass, a warning, a failure with a run of selected text,
 * and the block cursor — in that scheme's own colours **at the chosen text
 * size**. That is what makes the stepper worth having on this page rather than
 * anywhere else: every card on the screen redraws as it moves, so the number
 * turns into a thing you can see before you go back to a session.
 * `SchemePreview` is the same view the editor puts at the top of itself.
 */

import SwiftUI

struct AppearanceView: View {

    var themes: TerminalThemeStore = .shared

    /// The terminal's point size, mirrored into `@State` because `TextSize` is a
    /// `UserDefaults` façade with no observation on it — the shape the row in
    /// Settings used, kept so the stepper answers the finger rather than a store
    /// round trip.
    @State private var textSize = TextSize.stored

    /**
     * Light, dark, or the phone's own setting — moved here from the Settings
     * screen with the rest of the appearance.
     *
     * `@AppStorage` rather than the `@State`-mirror above it, and the difference
     * is which way the value has to travel. The text size is read by
     * `TerminalBridge`, which is told about a change by notification. This one
     * has to reach `RootView` — above the `TabView`, above this whole stack — on
     * the same frame as the tap, and `@AppStorage` on both ends is a live view
     * of the same defaults key rather than a binding threaded through four
     * screens that do not care.
     */
    @AppStorage(Appearance.key) private var appearance: Appearance = .system

    /// Which scheme the editor is open on, if any. Pushed rather than presented,
    /// because the rest of this app pushes and because the editor is a long
    /// screen a sheet would have shown three quarters of.
    @State private var editing: TerminalScheme?

    /// Which custom scheme the delete confirmation is about.
    @State private var deleting: TerminalScheme?

    /// Said only when a copy could not be made. See `TerminalThemeStore.copying`.
    @State private var problem: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    appTheme
                    size
                    schemes
                    footer
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
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $editing) { scheme in
            SchemeEditorView(themes: themes, schemeID: scheme.id)
        }
        .confirmationDialog("Delete this scheme?",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting { themes.delete(deleting.id) }
                deleting = nil
            }
            Button("Keep", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting.map { "\($0.name) is only on this phone. Deleting it cannot be undone." } ?? "")
        }
        .alert("Cannot copy", isPresented: Binding(get: { problem != nil },
                                                   set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - The app

    /**
     * Light, dark, or the phone's own — the whole app, not the terminal.
     *
     * Three segments rather than a switch, because there are three answers and
     * one of them is the important one: *System*, which is the default and the
     * only choice that keeps tracking the phone after it is made. A two-state
     * control would have had to drop it, and an app that cannot follow the
     * phone's own setting is an app that comes up white at midnight.
     *
     * The picker takes the whole width on its own line rather than sitting
     * beside a title. Rendered the other way at 375 points — the narrowest phone
     * this app supports — the three segments were 190 points between them and
     * "System" was clipped to "Syste".
     *
     * Writing to it writes the defaults key, which is the same key `RootView`
     * reads, so the window repaints on the same frame and the choice is already
     * saved. There is no Apply and nothing to confirm — including on this
     * screen, whose own paper and whose *Follow the app* card below change under
     * the finger that moved it.
     */
    private var appTheme: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchemeSectionCaption("The app")

            SchemeGroup {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 24)
                        Text("Theme")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.primary)
                        Spacer(minLength: 8)
                    }

                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("appearance.theme")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Size

    /**
     * The size, and the caption says who it is for.
     *
     * **"Every terminal"** rather than "Text size", because that is the half of
     * his sentence a stepper cannot say for itself — *"for the all of the
     * terminals with one setting"*. Somebody arriving here from a session they
     * could not read needs to know, before they touch it, that this is not a
     * setting about the session they came from. The row underneath is still
     * called Text size, because that is what it is.
     *
     * The caption covers **the colours below it as well**, which is why the
     * dot's sentence says so and why *Colours* is a plainer caption under it
     * rather than a second scope. Both settings answer to the same sentence and
     * a reader who has been told the scope once does not need it twice.
     */
    private var size: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchemeSectionCaption("Every terminal",
                                 about: "one setting for every terminal",
                                 info: "The size and the colours below are one choice, for every "
                                     + "session on every machine this phone is paired with — not "
                                     + "per session and not per machine. A session that is already "
                                     + "open follows as soon as you change it; there is nothing to "
                                     + "reopen.")

            SchemeGroup {
                HStack(spacing: 12) {
                    // 19 light in a 24-point column, which is what every row
                    // icon in Settings is now set at — see `SettingsRowBody`.
                    // A 15-point regular glyph here is the SF Symbols default,
                    // and the SF Symbols default is precisely the look he
                    // complained about.
                    Image(systemName: "textformat.size")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24)
                    Text("Text size")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                    InfoDot(about: "text size",
                            text: "The column count is the font, so this resizes the session on "
                                + "the machine rather than magnifying it — which is what stops an "
                                + "agent's tables wrapping. Pinching inside a terminal changes the "
                                + "same setting.")
                    Spacer(minLength: 8)
                    Text(TextSize.label(textSize))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                    Stepper("Text size", value: $textSize,
                            in: TextSize.minimum...TextSize.maximum,
                            step: TextSize.step)
                        .labelsHidden()
                        // `save` is what tells every open terminal, so the
                        // stepper is wired straight at it rather than at a
                        // commit on the way out of this screen. See `TextSize`.
                        .onChange(of: textSize) { _, size in TextSize.save(size) }
                        .accessibilityIdentifier("settings.textSize")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

        }
    }

    // MARK: - Schemes

    private var schemes: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchemeSectionCaption("Colours")

            VStack(spacing: 10) {
                SchemeCard(scheme: nil,
                           name: "Follow the app",
                           note: colorScheme == .dark ? "Deck Dark right now" : "Deck Light right now",
                           size: textSize,
                           isSelected: themes.isFollowingApp,
                           colorScheme: colorScheme,
                           choose: { themes.followApp() },
                           edit: nil,
                           remove: nil)

                ForEach(themes.schemes) { scheme in
                    SchemeCard(scheme: scheme,
                               name: scheme.name,
                               note: scheme.isBuiltIn ? nil : "Yours",
                               size: textSize,
                               isSelected: scheme.id == themes.selectedID,
                               colorScheme: colorScheme,
                               choose: { themes.select(scheme.id) },
                               edit: { edit(scheme) },
                               remove: scheme.isBuiltIn ? nil : { deleting = scheme })
                }
            }
        }
    }

    /**
     * Five words, and the rest of it behind the dot.
     *
     * *"we don't need this much of big descriptions under each."* This was two
     * paragraphs — the scope of the choice, and what editing a shipped scheme
     * does — and both of them were explanation rather than anything somebody
     * has to have in front of them while choosing a colour.
     *
     * **The half-line that stays is not a leftover.** Somebody who changes the
     * colour on their desktop and then picks the phone up is looking at what
     * seems like a bug, and a person who thinks they have found a bug does not
     * tap an ⓘ to check. So the scope is said out loud and the reasoning is one
     * tap away. "Stands alone" rather than "does not sync": the second
     * describes a missing feature, the first describes the design.
     */
    private var footer: some View {
        HStack(spacing: 4) {
            Text("This phone's choice stands alone.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("appearance.scopeNote")

            InfoDot(about: "where this choice applies",
                    text: "Every machine keeps the scheme chosen in the app running on it, and "
                        + "changing one never changes the other.\n\nEditing a scheme that ships "
                        + "with \(Brand.name) makes a copy first, so Dracula stays Dracula. A copy "
                        + "can be renamed, edited and deleted.")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
    }

    /**
     * Open the editor on `scheme` — on a **copy** of it when it is one of the
     * built-ins, and the copy becomes the chosen one.
     *
     * Selecting the copy is the point rather than a side effect. Somebody taps
     * Edit on the scheme they are looking at because they want that scheme
     * different; the copy is identical at the instant it is made, so nothing on
     * screen changes, and from the first colour they touch the terminal behind
     * this screen is following them. Leaving the original selected would mean
     * editing a scheme nothing was drawn in.
     */
    private func edit(_ scheme: TerminalScheme) {
        if scheme.isBuiltIn {
            guard let copy = themes.copying(scheme) else {
                problem = "You already have \(TerminalScheme.maxCustomSchemes) schemes of your own. "
                    + "Delete one to make another."
                return
            }
            themes.select(copy.id)
            editing = copy
        } else {
            themes.select(scheme.id)
            editing = scheme
        }
    }
}

/* -------------------------------------------------------------------------- */
/* One scheme on the list                                                     */
/* -------------------------------------------------------------------------- */

/**
 * A card: the scheme rendered as terminal output, its name, and what can be done
 * to it.
 *
 * The whole card is the choose target and the verbs are a separate strip under
 * it, rather than a chevron that opens the editor and a dot that chooses.
 * Choosing is the common act by a long way — most people will pick Pure Black
 * and never open the editor at all — so it gets the large target, and
 * `contentShape` makes the padding part of it rather than only the ink.
 *
 * `scheme` is nil for the *Follow the app* row, which has no scheme to be: it
 * previews whichever of the app's two the phone is currently in, and has neither
 * an edit nor a delete.
 */
private struct SchemeCard: View {
    let scheme: TerminalScheme?
    let name: String
    let note: String?
    let size: CGFloat
    let isSelected: Bool
    let colorScheme: ColorScheme
    let choose: () -> Void
    let edit: (() -> Void)?
    let remove: (() -> Void)?

    private var identifier: String { scheme?.id ?? TerminalScheme.followAppID }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: choose) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17))
                            .foregroundStyle(isSelected ? Theme.accent : Theme.faint)
                        Text(name)
                            .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(Theme.primary)
                        if let note {
                            Text(note)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.faint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.pressed, in: Capsule())
                        }
                        Spacer(minLength: 8)
                    }

                    SchemePreview(scheme: scheme, size: size, colorScheme: colorScheme)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scheme.\(identifier)")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            if edit != nil || remove != nil {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)

                HStack(spacing: 0) {
                    if let edit {
                        Button(action: edit) {
                            Label(scheme?.isBuiltIn == false ? "Edit" : "Copy & edit",
                                  systemImage: scheme?.isBuiltIn == false
                                      ? "slider.horizontal.3" : "square.on.square")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("scheme.\(identifier).edit")
                    }

                    if let remove {
                        Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 22)
                        Button(action: remove) {
                            Label("Delete", systemImage: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.critical)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("scheme.\(identifier).delete")
                    }
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
        )
    }
}

/* -------------------------------------------------------------------------- */
/* The preview                                                                */
/* -------------------------------------------------------------------------- */

/**
 * Six lines of terminal output, drawn in a scheme.
 *
 * Not a row of swatches. The question somebody is actually asking is *can I read
 * a failing test on this*, and a dot cannot answer it — the ANSI red that looks
 * fine as a circle is the one that disappears into Solarized's ground. So this
 * renders what a terminal on this phone actually shows: a prompt, a branch name,
 * a pass, a warning, a failure, a run of selected text and the block cursor.
 * Ten of the twenty-one slots appear, which is every one an agent's output
 * routinely uses.
 *
 * **`brightBlack` is deliberately not one of them**, and that was found by
 * looking rather than by reasoning. It is the obvious slot for a dim prompt and
 * dim punctuation, and it was — until Solarized Dark, whose published
 * `brightBlack` is base03, *the same colour as its own background*. That is
 * correct Solarized and it is what a real terminal does with `ESC[90m`; but in
 * a six-line card whose whole job is to show somebody what a scheme looks like,
 * it drew a preview with no `$` and no brackets and made a scheme that is fine
 * look broken. So every character here is in a slot that no shipped palette maps
 * onto its own ground.
 *
 * Drawn at the terminal's own point size, in the same monospaced face
 * `TerminalBridge` builds, so a preview at nine point looks like a terminal at
 * nine point rather than like a preview.
 *
 * The lines are fixed text and deliberately not real output. Nothing here reads
 * a session — a preview that borrowed the last session's scrollback would put
 * whatever an agent printed onto the Settings screen, paths and all.
 */
struct SchemePreview: View {
    /// Nil means *follow the app*, which resolves to whichever of the app's own
    /// two the phone is in. See `TerminalPalette.resolved`.
    let scheme: TerminalScheme?
    let size: CGFloat
    let colorScheme: ColorScheme

    private var painted: TerminalScheme {
        TerminalPalette.resolved(scheme, style: colorScheme == .dark ? .dark : .light)
    }

    private func color(_ hex: String) -> Color { TerminalPalette.swiftUIColor(hex) }

    var body: some View {
        let s = painted
        return VStack(alignment: .leading, spacing: 2) {
            /*
             * Each line is one `Text` built from an `AttributedString`, not a
             * row of `Text` views in an `HStack`.
             *
             * Two reasons, and the second forced it. An `HStack` puts default
             * spacing between its children, which turns a monospaced grid into
             * something that only nearly lines up. And two runs need a
             * *background* — the selection and the block cursor are the only way
             * those colours can be seen at all — and `Text.background(_:)`
             * returns a view rather than a `Text`, so they could not be
             * concatenated. Attributed runs carry both colours inside a single
             * `Text`, which is also what a terminal is.
             */
            line(run("~/terminaldeck", s.brightBlue)
                 + run(" git:(", s.magenta)
                 + run("main", s.green)
                 + run(")", s.magenta))

            line(run("$ ", s.foreground) + run("npm test", s.foreground))

            line(run("✓ ", s.green)
                 + run("12,415", s.brightGreen)
                 + run(" passed", s.foreground))

            line(run("! ", s.yellow)
                 + run("2 skipped", s.brightCyan))

            // The one run drawn on the selection colour, because a scheme whose
            // selection swallows its own ink is only discoverable here.
            line(run("✗ ", s.red)
                 + run("FAIL ", s.brightRed)
                 + run("relay.test.ts", s.foreground, on: s.selectionBackground))

            // The block cursor, and the glyph under it — which is what
            // `cursorAccent` is for and the only place it can be seen.
            line(run("$ ", s.foreground)
                 + run("s", s.cursorAccent, on: s.cursor))
        }
        .font(.system(size: size, design: .monospaced))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(color(s.background), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // A hairline so a `#000000` card on a dark screen and a `#fafafa` card
        // on a light one still read as a rectangle rather than as a hole in the
        // page. `isLight` decides which way it leans.
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(s.isLight ? 0.14 : 0.10), lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel("\(scheme?.name ?? "Follow the app") preview")
    }

    /// One coloured run. `on:` is the background — the selection band and the
    /// block cursor, and nothing else in this preview has one.
    private func run(_ string: String, _ hex: String, on background: String? = nil) -> AttributedString {
        var text = AttributedString(string)
        text.foregroundColor = color(hex)
        if let background { text.backgroundColor = color(background) }
        return text
    }

    /// One line, pinned to the leading edge so a short line does not centre
    /// itself inside the card.
    private func line(_ content: AttributedString) -> some View {
        Text(content).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/* -------------------------------------------------------------------------- */
/* Chrome shared with the editor                                              */
/* -------------------------------------------------------------------------- */

/**
 * The same caption `DeckSettingsView` draws, available to this screen and the
 * editor. A second copy that drifted by two points is how two settings screens
 * stop looking like one product.
 *
 * It carries the ⓘ for anything that is about the **section** rather than about
 * one row in it — the note that used to be a paragraph under the last card,
 * where it was read after the decision it was meant to inform. Both are nil on
 * most captions, which is the point: a caption with a dot on it is saying there
 * is something here that the rows cannot say for themselves.
 */
struct SchemeSectionCaption: View {
    let text: String
    let about: String?
    let info: String?

    init(_ text: String, about: String? = nil, info: String? = nil) {
        self.text = text
        self.about = about
        self.info = info
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.faint)
            if let about, let info {
                InfoDot(about: about, text: info)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

struct SchemeGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
