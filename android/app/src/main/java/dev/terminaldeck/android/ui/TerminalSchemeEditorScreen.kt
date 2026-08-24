package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.ui.kit.DeckDestructiveText
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckTextField
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.FieldLabel
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space
import dev.terminaldeck.android.ui.theme.TerminalScheme
import dev.terminaldeck.android.ui.theme.TerminalSchemeStore
import dev.terminaldeck.android.ui.theme.TerminalSlot
import dev.terminaldeck.android.ui.theme.withTyped
import dev.terminaldeck.android.ui.theme.TerminalSchemes
import dev.terminaldeck.android.ui.theme.currentAppearance

/**
 * Edit one scheme, one colour at a time.
 *
 * ## Editing a built-in makes a copy, and the copy happens on the first change
 *
 * Not on entry, and not behind a *Duplicate* button somebody has to find first. On entry this screen
 * shows the built-in exactly as it shipped, because opening a scheme to look at its hexes is a
 * reasonable thing to do and should not litter the list with copies. The moment a colour actually
 * changes, the scheme being edited becomes a copy — with a new id, a name derived from the original,
 * and the selection moved onto it so that the change somebody just made is the change they are
 * looking at.
 *
 * The reason the built-in is not simply edited in place is that a built-in is a **shared name**. If
 * "Nord" on this phone were somebody's adjusted Nord, then *use Nord* would stop meaning one thing
 * across their machines — which is the whole property the ids exist to hold, on a feature whose
 * entire point was that the choice is the same one on the phone, the Mac and the PC.
 *
 * ## Why every change is saved immediately
 *
 * Because the preview at the top of this screen is not the interesting one — the session behind it
 * is. Writing on each valid keystroke is what makes an open terminal repaint while somebody is still
 * looking at the hex field, which is the only way to tell whether `#8ae234` is the green you meant.
 * A Save button would mean choosing colours blind and finding out afterwards.
 *
 * ## Half-typed text is not a colour
 *
 * The field keeps what was typed and the scheme keeps the last thing that parsed. Somebody clearing
 * a field to retype it goes through `#`, `#8`, `#8a` — none of which are colours — and a screen that
 * committed those would flash the terminal black three times per edit. `TerminalScheme.normalise`
 * decides, and the row goes quiet-red until it says yes.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalSchemeEditorScreen(schemeId: String, onBack: () -> Unit) {
    val context = LocalContext.current
    val colors = DeckTheme.colors
    val dark = currentAppearance().isDark(LocalConfiguration.current)

    val opened = remember(schemeId) {
        TerminalSchemeStore.scheme(schemeId) ?: TerminalSchemes.forAppearance(dark)
    }

    /** What is being edited *now* — the built-in on entry, the copy once one exists. */
    var working by remember(schemeId) { mutableStateOf(opened) }

    /**
     * What is in each field, which is not the same as what is in the scheme.
     *
     * Keyed on the route's id rather than on `working.id`, deliberately: making a copy changes the
     * id mid-keystroke, and a draft map keyed on the scheme would reset the field somebody is
     * typing into at exactly that moment.
     */
    val drafts = remember(schemeId) { mutableStateMapOf<TerminalSlot, String>() }

    val isBuiltIn = working.id in TerminalSchemes.builtInIds

    /**
     * Commit a change, copying the built-in first if this is the first one.
     *
     * Selecting the copy is part of committing rather than a separate offer: somebody who changes a
     * colour is asking to see that colour, and leaving them on the original while a copy of it
     * accumulates their edits invisibly is the worst of both.
     */
    fun apply(next: TerminalScheme) {
        if (next.id in TerminalSchemes.builtInIds) {
            val copy = next.copyForEditing(
                newId = TerminalSchemeStore.newId(),
                newName = TerminalSchemeStore.copyName(opened.name),
            )
            TerminalSchemeStore.save(context, copy)
            TerminalSchemeStore.select(context, copy.id)
            working = copy
        } else {
            TerminalSchemeStore.save(context, next)
            working = next
        }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = working.name, onBack = onBack) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .imePadding()
                .navigationBarsPadding(),
        ) {
            TerminalSchemePreview(working, modifier = Modifier.testTag("editor.preview"))

            if (isBuiltIn) {
                DeckFootnote(
                    "${opened.name} ships with the app. Changing any colour here saves your own " +
                        "copy and leaves the original alone."
                )
            } else {
                Spacer(Modifier.height(Space.x4))
                FieldLabel("Name")
                DeckTextField(
                    value = working.name,
                    onValueChange = { if (it != working.name) apply(working.copy(name = it)) },
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
                    modifier = Modifier.testTag("editor.name"),
                )
            }

            Spacer(Modifier.height(Space.x5))
            SectionCaption("Terminal")
            DeckGroup {
                listOf(TerminalSlot.Background, TerminalSlot.Foreground, TerminalSlot.Cursor)
                    .forEachIndexed { index, slot ->
                        if (index > 0) DeckDivider(startIndent = Space.card)
                        ColourRow(slot, working, drafts, ::apply)
                    }
            }

            Spacer(Modifier.height(Space.x5))
            SectionCaption("Stored for your other machines")
            DeckGroup {
                listOf(TerminalSlot.CursorAccent, TerminalSlot.Selection)
                    .forEachIndexed { index, slot ->
                        if (index > 0) DeckDivider(startIndent = Space.card)
                        ColourRow(slot, working, drafts, ::apply)
                    }
            }
            DeckFootnote(
                "This phone's terminal inverts for a selection and for the text under the cursor, " +
                    "so these two change nothing here. They travel with the scheme so it is still " +
                    "whole on a desktop."
            )

            Spacer(Modifier.height(Space.x5))
            SectionCaption("ANSI colours")
            DeckGroup {
                TerminalSlot.entries.drop(5).forEachIndexed { index, slot ->
                    if (index > 0) DeckDivider(startIndent = Space.card)
                    ColourRow(slot, working, drafts, ::apply)
                }
            }

            if (!isBuiltIn) {
                Spacer(Modifier.height(Space.x6))
                DeckGroup {
                    DeckDestructiveText(
                        label = "Delete this scheme",
                        modifier = Modifier.testTag("editor.delete"),
                        onClick = {
                            TerminalSchemeStore.delete(context, working.id)
                            onBack()
                        },
                    )
                }
                DeckFootnote("The terminal goes back to matching the app's appearance.")
            }

            Spacer(Modifier.height(Space.x8))
        }
    }
}

/**
 * One colour: a swatch, its name, and the hex behind it.
 *
 * The swatch is the value rather than a decoration — it is drawn from whatever the field currently
 * parses to, so a mistyped hex stops updating it and the row says why. The field is monospace,
 * because a hex is a measurement and proportional digits in a colour code are how a `0` and an `O`
 * get confused — and eight digits fit in it as well as six, which the selection row needs.
 */
@Composable
private fun ColourRow(
    slot: TerminalSlot,
    scheme: TerminalScheme,
    drafts: MutableMap<TerminalSlot, String>,
    apply: (TerminalScheme) -> Unit,
) {
    val colors = DeckTheme.colors
    val stored = slot.read(scheme)
    val typed = drafts[slot] ?: stored
    // Slot-aware, because the selection is the one colour that may be written `#rrggbbaa` — see
    // `TerminalSlot.carriesAlpha`. Passing `false` here would put "Not a colour" under six of the
    // shipped schemes and paint their swatch black. The swatch itself is the opaque part either
    // way: sixteen per cent of the accent in a 28dp chip is an empty square, not a colour.
    val parsed = TerminalScheme.parseOrNull(typed, slot.carriesAlpha)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Space.card, vertical = Space.x2),
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(Radius.small)
                .background(Color(parsed ?: TerminalScheme.parse(stored, slot.carriesAlpha)))
                .border(1.dp, colors.hairline, Radius.small)
        )
        Spacer(Modifier.width(Space.x3))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = slot.label,
                style = DeckType.body,
                color = if (slot.paintedHere) colors.primary else colors.secondary,
            )
            if (parsed == null) {
                Text(
                    text = "Not a colour",
                    style = DeckType.footnote,
                    color = colors.critical,
                )
            }
        }
        Spacer(Modifier.width(Space.x2))
        DeckTextField(
            value = typed,
            onValueChange = { next ->
                drafts[slot] = next
                // `withTyped` decides; see its note for why "the same colour again" is a refusal
                // rather than a harmless write.
                scheme.withTyped(slot, next)?.let(apply)
            },
            mono = true,
            placeholder = "#000000",
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii),
            modifier = Modifier
                .width(124.dp)
                .testTag("colour.${slot.name}"),
        )
    }
}
